// External scanner for the **zortex** Tree‑sitter grammar.
// It provides `indent` / `dedent` tokens so that the parser can distinguish
// block levels by left‑padding (space characters) – similar to Markdown list
// handling.
//
// Integration notes (to be added to `zortex.grammar.js`):
// ------------------------------------------------------
//   externals: $ => [ $.indent, $.dedent ],
//   conflicts: $ => [ /* …rules that may need it… */ ],
//
//   At the start of each block‑capable rule (e.g. `list_item`, `paragraph`),
//   accept optional leading $.indent / $.dedent tokens so the parser’s state
//   tracks nesting correctly.  Example list rule update:
//
//     list: $ => repeat1(seq(optional($.indent), $.list_item, optional($.dedent))),
//
//   This file purposefully does *only* indentation tracking. Later we can add
//   list‑marker look‑ahead or other block‑specific tokens in this scanner.
// -------------------------------------------------------------------------

#include <tree_sitter/parser.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifdef _MSC_VER
#define inline __inline
#endif

enum TokenType {
  TOKEN_INDENT,
  TOKEN_DEDENT,
};

// Maximum reasonable nesting depth for list/indent blocks.
#define MAX_INDENT_DEPTH 128

typedef struct {
  uint16_t indent_lengths[MAX_INDENT_DEPTH];
  uint16_t depth;              // number of active indentation levels (≥1, level 0 is 0 spaces)
  uint16_t pending_dedents;    // how many DEDENT tokens still need to be emitted
} ScannerState;

static inline void scanner_state_init(ScannerState *state) {
  state->indent_lengths[0] = 0;  // base level (document root)
  state->depth = 1;
  state->pending_dedents = 0;
}

// ──────────────────────────────────────────────────────────────────────────
//  Tree‑sitter scanner API
// ──────────────────────────────────────────────────────────────────────────

void *tree_sitter_zortex_external_scanner_create(void) {
  ScannerState *state = (ScannerState *)malloc(sizeof(ScannerState));
  scanner_state_init(state);
  return state;
}

void tree_sitter_zortex_external_scanner_destroy(void *payload) {
  free(payload);
}

void tree_sitter_zortex_external_scanner_reset(void *payload) {
  scanner_state_init((ScannerState *)payload);
}

// Serialize: write depth, then the stack of indent lengths, then pending_dedents.
unsigned tree_sitter_zortex_external_scanner_serialize(void *payload, char *buffer) {
  ScannerState *state = (ScannerState *)payload;
  unsigned size = 0;

  memcpy(buffer + size, &state->depth, sizeof(state->depth));
  size += sizeof(state->depth);

  memcpy(buffer + size, &state->pending_dedents, sizeof(state->pending_dedents));
  size += sizeof(state->pending_dedents);

  unsigned i;
  for (i = 0; i < state->depth; i++) {
    memcpy(buffer + size, &state->indent_lengths[i], sizeof(uint16_t));
    size += sizeof(uint16_t);
  }
  return size;
}

void tree_sitter_zortex_external_scanner_deserialize(void *payload, const char *buffer, unsigned length) {
  ScannerState *state = (ScannerState *)payload;
  unsigned offset = 0;
  if (length < sizeof(state->depth) + sizeof(state->pending_dedents)) {
    // corrupted snapshot – reset
    scanner_state_init(state);
    return;
  }

  memcpy(&state->depth, buffer + offset, sizeof(state->depth));
  offset += sizeof(state->depth);

  memcpy(&state->pending_dedents, buffer + offset, sizeof(state->pending_dedents));
  offset += sizeof(state->pending_dedents);

  if (state->depth > MAX_INDENT_DEPTH) {
    scanner_state_init(state);
    return;
  }

  unsigned i;
  for (i = 0; i < state->depth && offset + sizeof(uint16_t) <= length; i++) {
    memcpy(&state->indent_lengths[i], buffer + offset, sizeof(uint16_t));
    offset += sizeof(uint16_t);
  }

  // If snapshot was truncated, reset.
  if (i < state->depth) {
    scanner_state_init(state);
  }
}

//  Helper: consume consecutive space characters and return count.
static inline uint16_t count_leading_spaces(TSLexer *lexer) {
  uint16_t count = 0;
  while (lexer->lookahead == ' ') {
    count += 1;
    lexer->advance(lexer, true); // skip + mark as trivia (whitespace)
  }
  return count;
}

//  Skip over optional carriage return in CRLF.
static inline void skip_optional_cr(TSLexer *lexer) {
  if (lexer->lookahead == '\r') {
    lexer->advance(lexer, true);
  }
}

//  Main scanning routine.
bool tree_sitter_zortex_external_scanner_scan(void *payload, TSLexer *lexer, const bool *valid_symbols) {
  ScannerState *state = (ScannerState *)payload;

  // If we still owe dedent(s), deliver them immediately (one per invocation).
  if (state->pending_dedents > 0 && valid_symbols[TOKEN_DEDENT]) {
    state->pending_dedents -= 1;
    state->depth -= 1;
    lexer->result_symbol = TOKEN_DEDENT;
    return true;
  }

  // Scanner only triggers at start‑of‑line (column 0) – otherwise bail.
  if (lexer->get_column(lexer) != 0) return false;

  // We only care if either indent or dedent is a valid symbol at this position.
  bool want_indent = valid_symbols[TOKEN_INDENT];
  bool want_dedent = valid_symbols[TOKEN_DEDENT];
  if (!want_indent && !want_dedent) return false;

  // Peek next char to differentiate blank lines.
  // Consume any whitespace (spaces).
  uint16_t indent = count_leading_spaces(lexer);

  // If the line is blank (newline, carriage return, or EOF) we ignore indent logic.
  if (lexer->lookahead == '\n' || lexer->lookahead == '\0') {
    // Allow parser to handle blank line via other rules; no indent/dedent token.
    return false;
  }

  // Compute indent diff relative to current top of stack.
  uint16_t current_indent = state->indent_lengths[state->depth - 1];

  if (indent > current_indent) {
    if (!want_indent) return false;
    // Push new indent level.
    if (state->depth == MAX_INDENT_DEPTH) return false; // overflow → ignore
    state->indent_lengths[state->depth++] = indent;
    lexer->result_symbol = TOKEN_INDENT;
    return true;
  }

  if (indent < current_indent) {
    // Must emit one or more DEDENTs; queue them.
    // Determine how many levels to pop.
    uint16_t target_depth = state->depth;
    while (target_depth > 0 && state->indent_lengths[target_depth - 1] > indent) {
      target_depth -= 1;
    }

    // If indent does not match any previous level, treat as syntax error →
    // create a virtual level to align (Markdown forgiving). For now we align.
    if (state->indent_lengths[target_depth - 1] != indent) {
      // Push new artificial level to avoid mismatch.
      if (state->depth == MAX_INDENT_DEPTH) return false;
      state->indent_lengths[target_depth] = indent;
      state->depth = target_depth + 1;
      if (!want_indent) return false;
      lexer->result_symbol = TOKEN_INDENT;
      return true;
    }

    // Schedule dedents.
    state->pending_dedents = (state->depth - target_depth) - 1;
    state->depth = target_depth;
    if (!want_dedent) return false;
    lexer->result_symbol = TOKEN_DEDENT;
    return true;
  }

  // indent == current_indent → no indent change.
  return false;
}

