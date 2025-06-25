#include "tree_sitter/parser.h"

#if defined(__GNUC__) || defined(__clang__)
#pragma GCC diagnostic ignored "-Wmissing-field-initializers"
#endif

#define LANGUAGE_VERSION 14
#define STATE_COUNT 82
#define LARGE_STATE_COUNT 2
#define SYMBOL_COUNT 57
#define ALIAS_COUNT 0
#define TOKEN_COUNT 27
#define EXTERNAL_TOKEN_COUNT 0
#define FIELD_COUNT 6
#define MAX_ALIAS_SEQUENCE_LENGTH 6
#define PRODUCTION_ID_COUNT 10

enum ts_symbol_identifiers {
  anon_sym_AT_AT = 1,
  anon_sym_LF = 2,
  anon_sym_AT = 3,
  sym_heading_marker = 4,
  anon_sym_COLON = 5,
  sym_label_name = 6,
  anon_sym_DASH = 7,
  anon_sym_SPACE = 8,
  sym_ordered_marker = 9,
  anon_sym_BQUOTE_BQUOTE_BQUOTE = 10,
  aux_sym_code_block_token1 = 11,
  aux_sym_code_line_token1 = 12,
  anon_sym_DOLLAR_DOLLAR = 13,
  aux_sym_paragraph_start_token1 = 14,
  anon_sym_STAR_STAR_STAR = 15,
  anon_sym_STAR_STAR = 16,
  anon_sym_STAR = 17,
  anon_sym_BQUOTE = 18,
  aux_sym_inline_code_token1 = 19,
  anon_sym_LBRACK = 20,
  aux_sym_link_token1 = 21,
  anon_sym_RBRACK = 22,
  anon_sym_LPAREN = 23,
  aux_sym_link_token2 = 24,
  anon_sym_RPAREN = 25,
  sym_text = 26,
  sym_document = 27,
  sym_article_header = 28,
  sym_tag_line = 29,
  sym_block = 30,
  sym_heading = 31,
  sym_label = 32,
  sym_list = 33,
  sym_list_item = 34,
  sym_code_block = 35,
  sym_code_line = 36,
  sym_latex_block = 37,
  sym_paragraph = 38,
  sym_paragraph_start = 39,
  sym_paragraph_line = 40,
  sym__inline = 41,
  sym_bolditalic = 42,
  sym_bold = 43,
  sym_italic = 44,
  sym_inline_code = 45,
  sym_link = 46,
  sym_line_content = 47,
  sym_blank_line = 48,
  aux_sym_document_repeat1 = 49,
  aux_sym_document_repeat2 = 50,
  aux_sym_document_repeat3 = 51,
  aux_sym_list_repeat1 = 52,
  aux_sym_list_item_repeat1 = 53,
  aux_sym_code_block_repeat1 = 54,
  aux_sym_paragraph_repeat1 = 55,
  aux_sym_bolditalic_repeat1 = 56,
};

static const char * const ts_symbol_names[] = {
  [ts_builtin_sym_end] = "end",
  [anon_sym_AT_AT] = "@@",
  [anon_sym_LF] = "\n",
  [anon_sym_AT] = "@",
  [sym_heading_marker] = "heading_marker",
  [anon_sym_COLON] = ":",
  [sym_label_name] = "label_name",
  [anon_sym_DASH] = "-",
  [anon_sym_SPACE] = " ",
  [sym_ordered_marker] = "ordered_marker",
  [anon_sym_BQUOTE_BQUOTE_BQUOTE] = "```",
  [aux_sym_code_block_token1] = "code_block_token1",
  [aux_sym_code_line_token1] = "code_line_token1",
  [anon_sym_DOLLAR_DOLLAR] = "$$",
  [aux_sym_paragraph_start_token1] = "paragraph_start_token1",
  [anon_sym_STAR_STAR_STAR] = "***",
  [anon_sym_STAR_STAR] = "**",
  [anon_sym_STAR] = "*",
  [anon_sym_BQUOTE] = "`",
  [aux_sym_inline_code_token1] = "inline_code_token1",
  [anon_sym_LBRACK] = "[",
  [aux_sym_link_token1] = "link_token1",
  [anon_sym_RBRACK] = "]",
  [anon_sym_LPAREN] = "(",
  [aux_sym_link_token2] = "link_token2",
  [anon_sym_RPAREN] = ")",
  [sym_text] = "text",
  [sym_document] = "document",
  [sym_article_header] = "article_header",
  [sym_tag_line] = "tag_line",
  [sym_block] = "block",
  [sym_heading] = "heading",
  [sym_label] = "label",
  [sym_list] = "list",
  [sym_list_item] = "list_item",
  [sym_code_block] = "code_block",
  [sym_code_line] = "code_line",
  [sym_latex_block] = "latex_block",
  [sym_paragraph] = "paragraph",
  [sym_paragraph_start] = "paragraph_start",
  [sym_paragraph_line] = "paragraph_line",
  [sym__inline] = "_inline",
  [sym_bolditalic] = "bolditalic",
  [sym_bold] = "bold",
  [sym_italic] = "italic",
  [sym_inline_code] = "inline_code",
  [sym_link] = "link",
  [sym_line_content] = "line_content",
  [sym_blank_line] = "blank_line",
  [aux_sym_document_repeat1] = "document_repeat1",
  [aux_sym_document_repeat2] = "document_repeat2",
  [aux_sym_document_repeat3] = "document_repeat3",
  [aux_sym_list_repeat1] = "list_repeat1",
  [aux_sym_list_item_repeat1] = "list_item_repeat1",
  [aux_sym_code_block_repeat1] = "code_block_repeat1",
  [aux_sym_paragraph_repeat1] = "paragraph_repeat1",
  [aux_sym_bolditalic_repeat1] = "bolditalic_repeat1",
};

static const TSSymbol ts_symbol_map[] = {
  [ts_builtin_sym_end] = ts_builtin_sym_end,
  [anon_sym_AT_AT] = anon_sym_AT_AT,
  [anon_sym_LF] = anon_sym_LF,
  [anon_sym_AT] = anon_sym_AT,
  [sym_heading_marker] = sym_heading_marker,
  [anon_sym_COLON] = anon_sym_COLON,
  [sym_label_name] = sym_label_name,
  [anon_sym_DASH] = anon_sym_DASH,
  [anon_sym_SPACE] = anon_sym_SPACE,
  [sym_ordered_marker] = sym_ordered_marker,
  [anon_sym_BQUOTE_BQUOTE_BQUOTE] = anon_sym_BQUOTE_BQUOTE_BQUOTE,
  [aux_sym_code_block_token1] = aux_sym_code_block_token1,
  [aux_sym_code_line_token1] = aux_sym_code_line_token1,
  [anon_sym_DOLLAR_DOLLAR] = anon_sym_DOLLAR_DOLLAR,
  [aux_sym_paragraph_start_token1] = aux_sym_paragraph_start_token1,
  [anon_sym_STAR_STAR_STAR] = anon_sym_STAR_STAR_STAR,
  [anon_sym_STAR_STAR] = anon_sym_STAR_STAR,
  [anon_sym_STAR] = anon_sym_STAR,
  [anon_sym_BQUOTE] = anon_sym_BQUOTE,
  [aux_sym_inline_code_token1] = aux_sym_inline_code_token1,
  [anon_sym_LBRACK] = anon_sym_LBRACK,
  [aux_sym_link_token1] = aux_sym_link_token1,
  [anon_sym_RBRACK] = anon_sym_RBRACK,
  [anon_sym_LPAREN] = anon_sym_LPAREN,
  [aux_sym_link_token2] = aux_sym_link_token2,
  [anon_sym_RPAREN] = anon_sym_RPAREN,
  [sym_text] = sym_text,
  [sym_document] = sym_document,
  [sym_article_header] = sym_article_header,
  [sym_tag_line] = sym_tag_line,
  [sym_block] = sym_block,
  [sym_heading] = sym_heading,
  [sym_label] = sym_label,
  [sym_list] = sym_list,
  [sym_list_item] = sym_list_item,
  [sym_code_block] = sym_code_block,
  [sym_code_line] = sym_code_line,
  [sym_latex_block] = sym_latex_block,
  [sym_paragraph] = sym_paragraph,
  [sym_paragraph_start] = sym_paragraph_start,
  [sym_paragraph_line] = sym_paragraph_line,
  [sym__inline] = sym__inline,
  [sym_bolditalic] = sym_bolditalic,
  [sym_bold] = sym_bold,
  [sym_italic] = sym_italic,
  [sym_inline_code] = sym_inline_code,
  [sym_link] = sym_link,
  [sym_line_content] = sym_line_content,
  [sym_blank_line] = sym_blank_line,
  [aux_sym_document_repeat1] = aux_sym_document_repeat1,
  [aux_sym_document_repeat2] = aux_sym_document_repeat2,
  [aux_sym_document_repeat3] = aux_sym_document_repeat3,
  [aux_sym_list_repeat1] = aux_sym_list_repeat1,
  [aux_sym_list_item_repeat1] = aux_sym_list_item_repeat1,
  [aux_sym_code_block_repeat1] = aux_sym_code_block_repeat1,
  [aux_sym_paragraph_repeat1] = aux_sym_paragraph_repeat1,
  [aux_sym_bolditalic_repeat1] = aux_sym_bolditalic_repeat1,
};

static const TSSymbolMetadata ts_symbol_metadata[] = {
  [ts_builtin_sym_end] = {
    .visible = false,
    .named = true,
  },
  [anon_sym_AT_AT] = {
    .visible = true,
    .named = false,
  },
  [anon_sym_LF] = {
    .visible = true,
    .named = false,
  },
  [anon_sym_AT] = {
    .visible = true,
    .named = false,
  },
  [sym_heading_marker] = {
    .visible = true,
    .named = true,
  },
  [anon_sym_COLON] = {
    .visible = true,
    .named = false,
  },
  [sym_label_name] = {
    .visible = true,
    .named = true,
  },
  [anon_sym_DASH] = {
    .visible = true,
    .named = false,
  },
  [anon_sym_SPACE] = {
    .visible = true,
    .named = false,
  },
  [sym_ordered_marker] = {
    .visible = true,
    .named = true,
  },
  [anon_sym_BQUOTE_BQUOTE_BQUOTE] = {
    .visible = true,
    .named = false,
  },
  [aux_sym_code_block_token1] = {
    .visible = false,
    .named = false,
  },
  [aux_sym_code_line_token1] = {
    .visible = false,
    .named = false,
  },
  [anon_sym_DOLLAR_DOLLAR] = {
    .visible = true,
    .named = false,
  },
  [aux_sym_paragraph_start_token1] = {
    .visible = false,
    .named = false,
  },
  [anon_sym_STAR_STAR_STAR] = {
    .visible = true,
    .named = false,
  },
  [anon_sym_STAR_STAR] = {
    .visible = true,
    .named = false,
  },
  [anon_sym_STAR] = {
    .visible = true,
    .named = false,
  },
  [anon_sym_BQUOTE] = {
    .visible = true,
    .named = false,
  },
  [aux_sym_inline_code_token1] = {
    .visible = false,
    .named = false,
  },
  [anon_sym_LBRACK] = {
    .visible = true,
    .named = false,
  },
  [aux_sym_link_token1] = {
    .visible = false,
    .named = false,
  },
  [anon_sym_RBRACK] = {
    .visible = true,
    .named = false,
  },
  [anon_sym_LPAREN] = {
    .visible = true,
    .named = false,
  },
  [aux_sym_link_token2] = {
    .visible = false,
    .named = false,
  },
  [anon_sym_RPAREN] = {
    .visible = true,
    .named = false,
  },
  [sym_text] = {
    .visible = true,
    .named = true,
  },
  [sym_document] = {
    .visible = true,
    .named = true,
  },
  [sym_article_header] = {
    .visible = true,
    .named = true,
  },
  [sym_tag_line] = {
    .visible = true,
    .named = true,
  },
  [sym_block] = {
    .visible = true,
    .named = true,
  },
  [sym_heading] = {
    .visible = true,
    .named = true,
  },
  [sym_label] = {
    .visible = true,
    .named = true,
  },
  [sym_list] = {
    .visible = true,
    .named = true,
  },
  [sym_list_item] = {
    .visible = true,
    .named = true,
  },
  [sym_code_block] = {
    .visible = true,
    .named = true,
  },
  [sym_code_line] = {
    .visible = true,
    .named = true,
  },
  [sym_latex_block] = {
    .visible = true,
    .named = true,
  },
  [sym_paragraph] = {
    .visible = true,
    .named = true,
  },
  [sym_paragraph_start] = {
    .visible = true,
    .named = true,
  },
  [sym_paragraph_line] = {
    .visible = true,
    .named = true,
  },
  [sym__inline] = {
    .visible = false,
    .named = true,
  },
  [sym_bolditalic] = {
    .visible = true,
    .named = true,
  },
  [sym_bold] = {
    .visible = true,
    .named = true,
  },
  [sym_italic] = {
    .visible = true,
    .named = true,
  },
  [sym_inline_code] = {
    .visible = true,
    .named = true,
  },
  [sym_link] = {
    .visible = true,
    .named = true,
  },
  [sym_line_content] = {
    .visible = true,
    .named = true,
  },
  [sym_blank_line] = {
    .visible = true,
    .named = true,
  },
  [aux_sym_document_repeat1] = {
    .visible = false,
    .named = false,
  },
  [aux_sym_document_repeat2] = {
    .visible = false,
    .named = false,
  },
  [aux_sym_document_repeat3] = {
    .visible = false,
    .named = false,
  },
  [aux_sym_list_repeat1] = {
    .visible = false,
    .named = false,
  },
  [aux_sym_list_item_repeat1] = {
    .visible = false,
    .named = false,
  },
  [aux_sym_code_block_repeat1] = {
    .visible = false,
    .named = false,
  },
  [aux_sym_paragraph_repeat1] = {
    .visible = false,
    .named = false,
  },
  [aux_sym_bolditalic_repeat1] = {
    .visible = false,
    .named = false,
  },
};

enum ts_field_identifiers {
  field_content = 1,
  field_language = 2,
  field_marker = 3,
  field_name = 4,
  field_text = 5,
  field_url = 6,
};

static const char * const ts_field_names[] = {
  [0] = NULL,
  [field_content] = "content",
  [field_language] = "language",
  [field_marker] = "marker",
  [field_name] = "name",
  [field_text] = "text",
  [field_url] = "url",
};

static const TSFieldMapSlice ts_field_map_slices[PRODUCTION_ID_COUNT] = {
  [1] = {.index = 0, .length = 1},
  [2] = {.index = 1, .length = 2},
  [3] = {.index = 3, .length = 1},
  [4] = {.index = 4, .length = 1},
  [5] = {.index = 5, .length = 1},
  [6] = {.index = 6, .length = 1},
  [7] = {.index = 7, .length = 1},
  [8] = {.index = 8, .length = 2},
  [9] = {.index = 10, .length = 2},
};

static const TSFieldMapEntry ts_field_map_entries[] = {
  [0] =
    {field_name, 1},
  [1] =
    {field_marker, 0},
    {field_text, 1},
  [3] =
    {field_name, 0},
  [4] =
    {field_marker, 0},
  [5] =
    {field_content, 2},
  [6] =
    {field_language, 1},
  [7] =
    {field_text, 1},
  [8] =
    {field_content, 3},
    {field_language, 1},
  [10] =
    {field_text, 1},
    {field_url, 4},
};

static const TSSymbol ts_alias_sequences[PRODUCTION_ID_COUNT][MAX_ALIAS_SEQUENCE_LENGTH] = {
  [0] = {0},
};

static const uint16_t ts_non_terminal_alias_map[] = {
  0,
};

static const TSStateId ts_primary_state_ids[STATE_COUNT] = {
  [0] = 0,
  [1] = 1,
  [2] = 2,
  [3] = 3,
  [4] = 4,
  [5] = 5,
  [6] = 6,
  [7] = 7,
  [8] = 8,
  [9] = 9,
  [10] = 10,
  [11] = 11,
  [12] = 12,
  [13] = 13,
  [14] = 14,
  [15] = 15,
  [16] = 16,
  [17] = 17,
  [18] = 18,
  [19] = 19,
  [20] = 20,
  [21] = 21,
  [22] = 22,
  [23] = 23,
  [24] = 24,
  [25] = 25,
  [26] = 26,
  [27] = 27,
  [28] = 28,
  [29] = 29,
  [30] = 30,
  [31] = 31,
  [32] = 32,
  [33] = 33,
  [34] = 34,
  [35] = 35,
  [36] = 36,
  [37] = 37,
  [38] = 38,
  [39] = 39,
  [40] = 40,
  [41] = 41,
  [42] = 42,
  [43] = 40,
  [44] = 44,
  [45] = 45,
  [46] = 46,
  [47] = 47,
  [48] = 48,
  [49] = 49,
  [50] = 50,
  [51] = 51,
  [52] = 47,
  [53] = 51,
  [54] = 51,
  [55] = 55,
  [56] = 56,
  [57] = 57,
  [58] = 58,
  [59] = 59,
  [60] = 60,
  [61] = 61,
  [62] = 62,
  [63] = 63,
  [64] = 64,
  [65] = 65,
  [66] = 66,
  [67] = 67,
  [68] = 68,
  [69] = 69,
  [70] = 70,
  [71] = 71,
  [72] = 72,
  [73] = 73,
  [74] = 74,
  [75] = 75,
  [76] = 76,
  [77] = 77,
  [78] = 78,
  [79] = 79,
  [80] = 80,
  [81] = 81,
};

static bool ts_lex(TSLexer *lexer, TSStateId state) {
  START_LEXER();
  eof = lexer->eof(lexer);
  switch (state) {
    case 0:
      if (eof) ADVANCE(21);
      ADVANCE_MAP(
        '\n', 23,
        '#', 31,
        '$', 8,
        '(', 75,
        ')', 79,
        '*', 67,
        '-', 39,
        ':', 32,
        '@', 25,
        '[', 71,
        ']', 74,
        '`', 68,
      );
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') SKIP(0);
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(44);
      if (('A' <= lookahead && lookahead <= 'Z') ||
          ('_' <= lookahead && lookahead <= 'z')) ADVANCE(45);
      END_STATE();
    case 1:
      if (lookahead == '\n') ADVANCE(23);
      if (lookahead == '$') ADVANCE(47);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(46);
      if (lookahead != 0) ADVANCE(52);
      END_STATE();
    case 2:
      ADVANCE_MAP(
        '\n', 23,
        '(', 76,
        '*', 67,
        '[', 71,
        '`', 68,
        '\t', 80,
        '\f', 80,
        '\r', 80,
        ' ', 80,
      );
      if (lookahead != 0 &&
          lookahead != ']') ADVANCE(82);
      END_STATE();
    case 3:
      if (lookahead == '\n') ADVANCE(23);
      if (lookahead == '*') ADVANCE(67);
      if (lookahead == '[') ADVANCE(71);
      if (lookahead == '`') ADVANCE(68);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(81);
      if (lookahead != 0 &&
          lookahead != ']') ADVANCE(82);
      END_STATE();
    case 4:
      if (lookahead == '\n') ADVANCE(23);
      if (lookahead == '`') ADVANCE(50);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(48);
      if (lookahead != 0) ADVANCE(52);
      END_STATE();
    case 5:
      if (lookahead == '\n') ADVANCE(23);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(58);
      if (lookahead != 0 &&
          lookahead != '#' &&
          lookahead != '$' &&
          lookahead != '-' &&
          (lookahead < '0' || '9' < lookahead) &&
          lookahead != '@' &&
          lookahead != '`') ADVANCE(62);
      END_STATE();
    case 6:
      if (lookahead == '\n') ADVANCE(23);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') SKIP(6);
      if (lookahead == '-' ||
          ('0' <= lookahead && lookahead <= '9') ||
          ('A' <= lookahead && lookahead <= 'Z') ||
          lookahead == '_' ||
          ('a' <= lookahead && lookahead <= 'z')) ADVANCE(45);
      END_STATE();
    case 7:
      if (lookahead == ' ') ADVANCE(40);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r') SKIP(7);
      END_STATE();
    case 8:
      if (lookahead == '$') ADVANCE(53);
      END_STATE();
    case 9:
      if (lookahead == '*') ADVANCE(10);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(81);
      if (lookahead != 0 &&
          lookahead != '\t' &&
          lookahead != '\n' &&
          lookahead != '[' &&
          lookahead != ']' &&
          lookahead != '`') ADVANCE(82);
      END_STATE();
    case 10:
      if (lookahead == '*') ADVANCE(64);
      END_STATE();
    case 11:
      if (lookahead == '*') ADVANCE(66);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(81);
      if (lookahead != 0 &&
          lookahead != '\t' &&
          lookahead != '\n' &&
          lookahead != '[' &&
          lookahead != ']' &&
          lookahead != '`') ADVANCE(82);
      END_STATE();
    case 12:
      if (lookahead == '`') ADVANCE(42);
      END_STATE();
    case 13:
      if (lookahead == '`') ADVANCE(12);
      END_STATE();
    case 14:
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(51);
      if (lookahead != 0 &&
          lookahead != '\t' &&
          lookahead != '\n') ADVANCE(52);
      END_STATE();
    case 15:
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(69);
      if (lookahead != 0 &&
          lookahead != '`') ADVANCE(70);
      END_STATE();
    case 16:
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(72);
      if (lookahead != 0 &&
          lookahead != ']') ADVANCE(73);
      END_STATE();
    case 17:
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(77);
      if (lookahead != 0 &&
          lookahead != ')') ADVANCE(78);
      END_STATE();
    case 18:
      if (eof) ADVANCE(21);
      ADVANCE_MAP(
        '\n', 23,
        ' ', 33,
        '#', 31,
        '$', 8,
        '-', 38,
        '@', 25,
        '`', 13,
        '\t', 55,
        '\f', 55,
        '\r', 55,
      );
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(36);
      if (('A' <= lookahead && lookahead <= 'Z') ||
          ('a' <= lookahead && lookahead <= 'z')) ADVANCE(37);
      if (lookahead != 0) ADVANCE(62);
      END_STATE();
    case 19:
      if (eof) ADVANCE(21);
      ADVANCE_MAP(
        '\n', 23,
        ' ', 34,
        '#', 31,
        '$', 8,
        '-', 38,
        '@', 24,
        '`', 13,
        '\t', 56,
        '\f', 56,
        '\r', 56,
      );
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(36);
      if (('A' <= lookahead && lookahead <= 'Z') ||
          ('a' <= lookahead && lookahead <= 'z')) ADVANCE(37);
      if (lookahead != 0) ADVANCE(62);
      END_STATE();
    case 20:
      if (eof) ADVANCE(21);
      ADVANCE_MAP(
        '\n', 23,
        ' ', 35,
        '#', 31,
        '$', 8,
        '-', 38,
        '`', 13,
        '\t', 57,
        '\f', 57,
        '\r', 57,
      );
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(36);
      if (('A' <= lookahead && lookahead <= 'Z') ||
          ('a' <= lookahead && lookahead <= 'z')) ADVANCE(37);
      if (lookahead != 0 &&
          (lookahead < '@' || 'Z' < lookahead)) ADVANCE(62);
      END_STATE();
    case 21:
      ACCEPT_TOKEN(ts_builtin_sym_end);
      END_STATE();
    case 22:
      ACCEPT_TOKEN(anon_sym_AT_AT);
      END_STATE();
    case 23:
      ACCEPT_TOKEN(anon_sym_LF);
      END_STATE();
    case 24:
      ACCEPT_TOKEN(anon_sym_AT);
      END_STATE();
    case 25:
      ACCEPT_TOKEN(anon_sym_AT);
      if (lookahead == '@') ADVANCE(22);
      END_STATE();
    case 26:
      ACCEPT_TOKEN(sym_heading_marker);
      END_STATE();
    case 27:
      ACCEPT_TOKEN(sym_heading_marker);
      if (lookahead == '#') ADVANCE(26);
      END_STATE();
    case 28:
      ACCEPT_TOKEN(sym_heading_marker);
      if (lookahead == '#') ADVANCE(27);
      END_STATE();
    case 29:
      ACCEPT_TOKEN(sym_heading_marker);
      if (lookahead == '#') ADVANCE(28);
      END_STATE();
    case 30:
      ACCEPT_TOKEN(sym_heading_marker);
      if (lookahead == '#') ADVANCE(29);
      END_STATE();
    case 31:
      ACCEPT_TOKEN(sym_heading_marker);
      if (lookahead == '#') ADVANCE(30);
      END_STATE();
    case 32:
      ACCEPT_TOKEN(anon_sym_COLON);
      END_STATE();
    case 33:
      ACCEPT_TOKEN(sym_label_name);
      if (lookahead == ' ') ADVANCE(33);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r') ADVANCE(55);
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(36);
      if (('A' <= lookahead && lookahead <= 'Z') ||
          ('a' <= lookahead && lookahead <= 'z')) ADVANCE(37);
      END_STATE();
    case 34:
      ACCEPT_TOKEN(sym_label_name);
      if (lookahead == ' ') ADVANCE(34);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r') ADVANCE(56);
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(36);
      if (('A' <= lookahead && lookahead <= 'Z') ||
          ('a' <= lookahead && lookahead <= 'z')) ADVANCE(37);
      END_STATE();
    case 35:
      ACCEPT_TOKEN(sym_label_name);
      if (lookahead == ' ') ADVANCE(35);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r') ADVANCE(57);
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(36);
      if (('A' <= lookahead && lookahead <= 'Z') ||
          ('a' <= lookahead && lookahead <= 'z')) ADVANCE(37);
      END_STATE();
    case 36:
      ACCEPT_TOKEN(sym_label_name);
      if (lookahead == '.') ADVANCE(41);
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(36);
      if (lookahead == ' ' ||
          ('A' <= lookahead && lookahead <= 'Z') ||
          ('a' <= lookahead && lookahead <= 'z')) ADVANCE(37);
      END_STATE();
    case 37:
      ACCEPT_TOKEN(sym_label_name);
      if (lookahead == ' ' ||
          ('0' <= lookahead && lookahead <= '9') ||
          ('A' <= lookahead && lookahead <= 'Z') ||
          ('a' <= lookahead && lookahead <= 'z')) ADVANCE(37);
      END_STATE();
    case 38:
      ACCEPT_TOKEN(anon_sym_DASH);
      END_STATE();
    case 39:
      ACCEPT_TOKEN(anon_sym_DASH);
      if (lookahead == '-' ||
          ('0' <= lookahead && lookahead <= '9') ||
          ('A' <= lookahead && lookahead <= 'Z') ||
          lookahead == '_' ||
          ('a' <= lookahead && lookahead <= 'z')) ADVANCE(45);
      END_STATE();
    case 40:
      ACCEPT_TOKEN(anon_sym_SPACE);
      if (lookahead == ' ') ADVANCE(40);
      END_STATE();
    case 41:
      ACCEPT_TOKEN(sym_ordered_marker);
      END_STATE();
    case 42:
      ACCEPT_TOKEN(anon_sym_BQUOTE_BQUOTE_BQUOTE);
      END_STATE();
    case 43:
      ACCEPT_TOKEN(anon_sym_BQUOTE_BQUOTE_BQUOTE);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(52);
      END_STATE();
    case 44:
      ACCEPT_TOKEN(aux_sym_code_block_token1);
      if (lookahead == '.') ADVANCE(41);
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(44);
      if (lookahead == '-' ||
          ('A' <= lookahead && lookahead <= 'Z') ||
          lookahead == '_' ||
          ('a' <= lookahead && lookahead <= 'z')) ADVANCE(45);
      END_STATE();
    case 45:
      ACCEPT_TOKEN(aux_sym_code_block_token1);
      if (lookahead == '-' ||
          ('0' <= lookahead && lookahead <= '9') ||
          ('A' <= lookahead && lookahead <= 'Z') ||
          lookahead == '_' ||
          ('a' <= lookahead && lookahead <= 'z')) ADVANCE(45);
      END_STATE();
    case 46:
      ACCEPT_TOKEN(aux_sym_code_line_token1);
      if (lookahead == '$') ADVANCE(47);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(46);
      if (lookahead != 0 &&
          lookahead != '\t' &&
          lookahead != '\n') ADVANCE(52);
      END_STATE();
    case 47:
      ACCEPT_TOKEN(aux_sym_code_line_token1);
      if (lookahead == '$') ADVANCE(54);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(52);
      END_STATE();
    case 48:
      ACCEPT_TOKEN(aux_sym_code_line_token1);
      if (lookahead == '`') ADVANCE(50);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(48);
      if (lookahead != 0 &&
          lookahead != '\t' &&
          lookahead != '\n') ADVANCE(52);
      END_STATE();
    case 49:
      ACCEPT_TOKEN(aux_sym_code_line_token1);
      if (lookahead == '`') ADVANCE(43);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(52);
      END_STATE();
    case 50:
      ACCEPT_TOKEN(aux_sym_code_line_token1);
      if (lookahead == '`') ADVANCE(49);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(52);
      END_STATE();
    case 51:
      ACCEPT_TOKEN(aux_sym_code_line_token1);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(51);
      if (lookahead != 0 &&
          lookahead != '\t' &&
          lookahead != '\n') ADVANCE(52);
      END_STATE();
    case 52:
      ACCEPT_TOKEN(aux_sym_code_line_token1);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(52);
      END_STATE();
    case 53:
      ACCEPT_TOKEN(anon_sym_DOLLAR_DOLLAR);
      END_STATE();
    case 54:
      ACCEPT_TOKEN(anon_sym_DOLLAR_DOLLAR);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(52);
      END_STATE();
    case 55:
      ACCEPT_TOKEN(aux_sym_paragraph_start_token1);
      ADVANCE_MAP(
        '\n', 23,
        ' ', 33,
        '#', 31,
        '$', 59,
        '-', 38,
        '@', 25,
        '`', 61,
        '\t', 55,
        '\f', 55,
        '\r', 55,
      );
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(36);
      if (('A' <= lookahead && lookahead <= 'Z') ||
          ('a' <= lookahead && lookahead <= 'z')) ADVANCE(37);
      if (lookahead != 0) ADVANCE(62);
      END_STATE();
    case 56:
      ACCEPT_TOKEN(aux_sym_paragraph_start_token1);
      ADVANCE_MAP(
        '\n', 23,
        ' ', 34,
        '#', 31,
        '$', 59,
        '-', 38,
        '@', 24,
        '`', 61,
        '\t', 56,
        '\f', 56,
        '\r', 56,
      );
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(36);
      if (('A' <= lookahead && lookahead <= 'Z') ||
          ('a' <= lookahead && lookahead <= 'z')) ADVANCE(37);
      if (lookahead != 0) ADVANCE(62);
      END_STATE();
    case 57:
      ACCEPT_TOKEN(aux_sym_paragraph_start_token1);
      ADVANCE_MAP(
        '\n', 23,
        ' ', 35,
        '#', 31,
        '$', 59,
        '-', 38,
        '@', 62,
        '`', 61,
        '\t', 57,
        '\f', 57,
        '\r', 57,
      );
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(36);
      if (('A' <= lookahead && lookahead <= 'Z') ||
          ('a' <= lookahead && lookahead <= 'z')) ADVANCE(37);
      if (lookahead != 0) ADVANCE(62);
      END_STATE();
    case 58:
      ACCEPT_TOKEN(aux_sym_paragraph_start_token1);
      if (lookahead == '\n') ADVANCE(23);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(58);
      if (lookahead == '#' ||
          lookahead == '$' ||
          lookahead == '-' ||
          ('0' <= lookahead && lookahead <= '9') ||
          lookahead == '@' ||
          lookahead == '`') ADVANCE(62);
      if (lookahead != 0) ADVANCE(62);
      END_STATE();
    case 59:
      ACCEPT_TOKEN(aux_sym_paragraph_start_token1);
      if (lookahead == '$') ADVANCE(53);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(62);
      END_STATE();
    case 60:
      ACCEPT_TOKEN(aux_sym_paragraph_start_token1);
      if (lookahead == '`') ADVANCE(42);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(62);
      END_STATE();
    case 61:
      ACCEPT_TOKEN(aux_sym_paragraph_start_token1);
      if (lookahead == '`') ADVANCE(60);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(62);
      END_STATE();
    case 62:
      ACCEPT_TOKEN(aux_sym_paragraph_start_token1);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(62);
      END_STATE();
    case 63:
      ACCEPT_TOKEN(anon_sym_STAR_STAR_STAR);
      END_STATE();
    case 64:
      ACCEPT_TOKEN(anon_sym_STAR_STAR);
      END_STATE();
    case 65:
      ACCEPT_TOKEN(anon_sym_STAR_STAR);
      if (lookahead == '*') ADVANCE(63);
      END_STATE();
    case 66:
      ACCEPT_TOKEN(anon_sym_STAR);
      END_STATE();
    case 67:
      ACCEPT_TOKEN(anon_sym_STAR);
      if (lookahead == '*') ADVANCE(65);
      END_STATE();
    case 68:
      ACCEPT_TOKEN(anon_sym_BQUOTE);
      END_STATE();
    case 69:
      ACCEPT_TOKEN(aux_sym_inline_code_token1);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(69);
      if (lookahead != 0 &&
          lookahead != '`') ADVANCE(70);
      END_STATE();
    case 70:
      ACCEPT_TOKEN(aux_sym_inline_code_token1);
      if (lookahead != 0 &&
          lookahead != '`') ADVANCE(70);
      END_STATE();
    case 71:
      ACCEPT_TOKEN(anon_sym_LBRACK);
      END_STATE();
    case 72:
      ACCEPT_TOKEN(aux_sym_link_token1);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(72);
      if (lookahead != 0 &&
          lookahead != ']') ADVANCE(73);
      END_STATE();
    case 73:
      ACCEPT_TOKEN(aux_sym_link_token1);
      if (lookahead != 0 &&
          lookahead != ']') ADVANCE(73);
      END_STATE();
    case 74:
      ACCEPT_TOKEN(anon_sym_RBRACK);
      END_STATE();
    case 75:
      ACCEPT_TOKEN(anon_sym_LPAREN);
      END_STATE();
    case 76:
      ACCEPT_TOKEN(anon_sym_LPAREN);
      if (lookahead != 0 &&
          lookahead != '\n' &&
          lookahead != '*' &&
          lookahead != '[' &&
          lookahead != ']' &&
          lookahead != '`') ADVANCE(82);
      END_STATE();
    case 77:
      ACCEPT_TOKEN(aux_sym_link_token2);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(77);
      if (lookahead != 0 &&
          lookahead != ')') ADVANCE(78);
      END_STATE();
    case 78:
      ACCEPT_TOKEN(aux_sym_link_token2);
      if (lookahead != 0 &&
          lookahead != ')') ADVANCE(78);
      END_STATE();
    case 79:
      ACCEPT_TOKEN(anon_sym_RPAREN);
      END_STATE();
    case 80:
      ACCEPT_TOKEN(sym_text);
      if (lookahead == '(') ADVANCE(76);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(80);
      if (lookahead != 0 &&
          lookahead != '\t' &&
          lookahead != '\n' &&
          lookahead != '*' &&
          lookahead != '[' &&
          lookahead != ']' &&
          lookahead != '`') ADVANCE(82);
      END_STATE();
    case 81:
      ACCEPT_TOKEN(sym_text);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(81);
      if (lookahead != 0 &&
          lookahead != '\t' &&
          lookahead != '\n' &&
          lookahead != '*' &&
          lookahead != '[' &&
          lookahead != ']' &&
          lookahead != '`') ADVANCE(82);
      END_STATE();
    case 82:
      ACCEPT_TOKEN(sym_text);
      if (lookahead != 0 &&
          lookahead != '\n' &&
          lookahead != '*' &&
          lookahead != '[' &&
          lookahead != ']' &&
          lookahead != '`') ADVANCE(82);
      END_STATE();
    default:
      return false;
  }
}

static const TSLexMode ts_lex_modes[STATE_COUNT] = {
  [0] = {.lex_state = 0},
  [1] = {.lex_state = 0},
  [2] = {.lex_state = 18},
  [3] = {.lex_state = 19},
  [4] = {.lex_state = 20},
  [5] = {.lex_state = 20},
  [6] = {.lex_state = 20},
  [7] = {.lex_state = 3},
  [8] = {.lex_state = 3},
  [9] = {.lex_state = 3},
  [10] = {.lex_state = 18},
  [11] = {.lex_state = 19},
  [12] = {.lex_state = 20},
  [13] = {.lex_state = 18},
  [14] = {.lex_state = 20},
  [15] = {.lex_state = 20},
  [16] = {.lex_state = 19},
  [17] = {.lex_state = 20},
  [18] = {.lex_state = 20},
  [19] = {.lex_state = 20},
  [20] = {.lex_state = 20},
  [21] = {.lex_state = 20},
  [22] = {.lex_state = 20},
  [23] = {.lex_state = 20},
  [24] = {.lex_state = 20},
  [25] = {.lex_state = 20},
  [26] = {.lex_state = 20},
  [27] = {.lex_state = 20},
  [28] = {.lex_state = 20},
  [29] = {.lex_state = 20},
  [30] = {.lex_state = 2},
  [31] = {.lex_state = 3},
  [32] = {.lex_state = 3},
  [33] = {.lex_state = 3},
  [34] = {.lex_state = 3},
  [35] = {.lex_state = 3},
  [36] = {.lex_state = 4},
  [37] = {.lex_state = 4},
  [38] = {.lex_state = 1},
  [39] = {.lex_state = 4},
  [40] = {.lex_state = 4},
  [41] = {.lex_state = 4},
  [42] = {.lex_state = 1},
  [43] = {.lex_state = 1},
  [44] = {.lex_state = 5},
  [45] = {.lex_state = 5},
  [46] = {.lex_state = 5},
  [47] = {.lex_state = 4},
  [48] = {.lex_state = 3},
  [49] = {.lex_state = 9},
  [50] = {.lex_state = 11},
  [51] = {.lex_state = 3},
  [52] = {.lex_state = 1},
  [53] = {.lex_state = 9},
  [54] = {.lex_state = 11},
  [55] = {.lex_state = 6},
  [56] = {.lex_state = 3},
  [57] = {.lex_state = 3},
  [58] = {.lex_state = 3},
  [59] = {.lex_state = 5},
  [60] = {.lex_state = 14},
  [61] = {.lex_state = 14},
  [62] = {.lex_state = 5},
  [63] = {.lex_state = 14},
  [64] = {.lex_state = 0},
  [65] = {.lex_state = 0},
  [66] = {.lex_state = 15},
  [67] = {.lex_state = 0},
  [68] = {.lex_state = 0},
  [69] = {.lex_state = 0},
  [70] = {.lex_state = 16},
  [71] = {.lex_state = 0},
  [72] = {.lex_state = 0},
  [73] = {.lex_state = 7},
  [74] = {.lex_state = 0},
  [75] = {.lex_state = 17},
  [76] = {.lex_state = 0},
  [77] = {.lex_state = 0},
  [78] = {.lex_state = 0},
  [79] = {.lex_state = 0},
  [80] = {.lex_state = 0},
  [81] = {.lex_state = 0},
};

static const uint16_t ts_parse_table[LARGE_STATE_COUNT][SYMBOL_COUNT] = {
  [0] = {
    [ts_builtin_sym_end] = ACTIONS(1),
    [anon_sym_AT_AT] = ACTIONS(1),
    [anon_sym_LF] = ACTIONS(1),
    [anon_sym_AT] = ACTIONS(1),
    [sym_heading_marker] = ACTIONS(1),
    [anon_sym_COLON] = ACTIONS(1),
    [anon_sym_DASH] = ACTIONS(1),
    [sym_ordered_marker] = ACTIONS(1),
    [aux_sym_code_block_token1] = ACTIONS(1),
    [anon_sym_DOLLAR_DOLLAR] = ACTIONS(1),
    [anon_sym_STAR_STAR_STAR] = ACTIONS(1),
    [anon_sym_STAR_STAR] = ACTIONS(1),
    [anon_sym_STAR] = ACTIONS(1),
    [anon_sym_BQUOTE] = ACTIONS(1),
    [anon_sym_LBRACK] = ACTIONS(1),
    [anon_sym_RBRACK] = ACTIONS(1),
    [anon_sym_LPAREN] = ACTIONS(1),
    [anon_sym_RPAREN] = ACTIONS(1),
  },
  [1] = {
    [sym_document] = STATE(69),
    [sym_article_header] = STATE(2),
    [aux_sym_document_repeat1] = STATE(2),
    [anon_sym_AT_AT] = ACTIONS(3),
  },
};

static const uint16_t ts_small_parse_table[] = {
  [0] = 16,
    ACTIONS(5), 1,
      ts_builtin_sym_end,
    ACTIONS(7), 1,
      anon_sym_AT_AT,
    ACTIONS(9), 1,
      anon_sym_LF,
    ACTIONS(11), 1,
      anon_sym_AT,
    ACTIONS(13), 1,
      sym_heading_marker,
    ACTIONS(15), 1,
      sym_label_name,
    ACTIONS(19), 1,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
    ACTIONS(21), 1,
      anon_sym_DOLLAR_DOLLAR,
    ACTIONS(23), 1,
      aux_sym_paragraph_start_token1,
    STATE(12), 1,
      sym_list_item,
    STATE(45), 1,
      sym_paragraph_start,
    ACTIONS(17), 2,
      anon_sym_DASH,
      sym_ordered_marker,
    STATE(3), 2,
      sym_tag_line,
      aux_sym_document_repeat2,
    STATE(4), 2,
      sym_block,
      aux_sym_document_repeat3,
    STATE(10), 2,
      sym_article_header,
      aux_sym_document_repeat1,
    STATE(18), 7,
      sym_heading,
      sym_label,
      sym_list,
      sym_code_block,
      sym_latex_block,
      sym_paragraph,
      sym_blank_line,
  [59] = 14,
    ACTIONS(9), 1,
      anon_sym_LF,
    ACTIONS(11), 1,
      anon_sym_AT,
    ACTIONS(13), 1,
      sym_heading_marker,
    ACTIONS(15), 1,
      sym_label_name,
    ACTIONS(19), 1,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
    ACTIONS(21), 1,
      anon_sym_DOLLAR_DOLLAR,
    ACTIONS(23), 1,
      aux_sym_paragraph_start_token1,
    ACTIONS(25), 1,
      ts_builtin_sym_end,
    STATE(12), 1,
      sym_list_item,
    STATE(45), 1,
      sym_paragraph_start,
    ACTIONS(17), 2,
      anon_sym_DASH,
      sym_ordered_marker,
    STATE(5), 2,
      sym_block,
      aux_sym_document_repeat3,
    STATE(11), 2,
      sym_tag_line,
      aux_sym_document_repeat2,
    STATE(18), 7,
      sym_heading,
      sym_label,
      sym_list,
      sym_code_block,
      sym_latex_block,
      sym_paragraph,
      sym_blank_line,
  [111] = 12,
    ACTIONS(9), 1,
      anon_sym_LF,
    ACTIONS(13), 1,
      sym_heading_marker,
    ACTIONS(15), 1,
      sym_label_name,
    ACTIONS(19), 1,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
    ACTIONS(21), 1,
      anon_sym_DOLLAR_DOLLAR,
    ACTIONS(23), 1,
      aux_sym_paragraph_start_token1,
    ACTIONS(25), 1,
      ts_builtin_sym_end,
    STATE(12), 1,
      sym_list_item,
    STATE(45), 1,
      sym_paragraph_start,
    ACTIONS(17), 2,
      anon_sym_DASH,
      sym_ordered_marker,
    STATE(6), 2,
      sym_block,
      aux_sym_document_repeat3,
    STATE(18), 7,
      sym_heading,
      sym_label,
      sym_list,
      sym_code_block,
      sym_latex_block,
      sym_paragraph,
      sym_blank_line,
  [156] = 12,
    ACTIONS(9), 1,
      anon_sym_LF,
    ACTIONS(13), 1,
      sym_heading_marker,
    ACTIONS(15), 1,
      sym_label_name,
    ACTIONS(19), 1,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
    ACTIONS(21), 1,
      anon_sym_DOLLAR_DOLLAR,
    ACTIONS(23), 1,
      aux_sym_paragraph_start_token1,
    ACTIONS(27), 1,
      ts_builtin_sym_end,
    STATE(12), 1,
      sym_list_item,
    STATE(45), 1,
      sym_paragraph_start,
    ACTIONS(17), 2,
      anon_sym_DASH,
      sym_ordered_marker,
    STATE(6), 2,
      sym_block,
      aux_sym_document_repeat3,
    STATE(18), 7,
      sym_heading,
      sym_label,
      sym_list,
      sym_code_block,
      sym_latex_block,
      sym_paragraph,
      sym_blank_line,
  [201] = 12,
    ACTIONS(29), 1,
      ts_builtin_sym_end,
    ACTIONS(31), 1,
      anon_sym_LF,
    ACTIONS(34), 1,
      sym_heading_marker,
    ACTIONS(37), 1,
      sym_label_name,
    ACTIONS(43), 1,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
    ACTIONS(46), 1,
      anon_sym_DOLLAR_DOLLAR,
    ACTIONS(49), 1,
      aux_sym_paragraph_start_token1,
    STATE(12), 1,
      sym_list_item,
    STATE(45), 1,
      sym_paragraph_start,
    ACTIONS(40), 2,
      anon_sym_DASH,
      sym_ordered_marker,
    STATE(6), 2,
      sym_block,
      aux_sym_document_repeat3,
    STATE(18), 7,
      sym_heading,
      sym_label,
      sym_list,
      sym_code_block,
      sym_latex_block,
      sym_paragraph,
      sym_blank_line,
  [246] = 8,
    ACTIONS(52), 1,
      anon_sym_LF,
    ACTIONS(54), 1,
      anon_sym_STAR_STAR_STAR,
    ACTIONS(57), 1,
      anon_sym_STAR_STAR,
    ACTIONS(60), 1,
      anon_sym_STAR,
    ACTIONS(63), 1,
      anon_sym_BQUOTE,
    ACTIONS(66), 1,
      anon_sym_LBRACK,
    ACTIONS(69), 1,
      sym_text,
    STATE(7), 7,
      sym__inline,
      sym_bolditalic,
      sym_bold,
      sym_italic,
      sym_inline_code,
      sym_link,
      aux_sym_list_item_repeat1,
  [277] = 8,
    ACTIONS(72), 1,
      anon_sym_LF,
    ACTIONS(74), 1,
      anon_sym_STAR_STAR_STAR,
    ACTIONS(76), 1,
      anon_sym_STAR_STAR,
    ACTIONS(78), 1,
      anon_sym_STAR,
    ACTIONS(80), 1,
      anon_sym_BQUOTE,
    ACTIONS(82), 1,
      anon_sym_LBRACK,
    ACTIONS(84), 1,
      sym_text,
    STATE(7), 7,
      sym__inline,
      sym_bolditalic,
      sym_bold,
      sym_italic,
      sym_inline_code,
      sym_link,
      aux_sym_list_item_repeat1,
  [308] = 7,
    ACTIONS(74), 1,
      anon_sym_STAR_STAR_STAR,
    ACTIONS(76), 1,
      anon_sym_STAR_STAR,
    ACTIONS(78), 1,
      anon_sym_STAR,
    ACTIONS(80), 1,
      anon_sym_BQUOTE,
    ACTIONS(82), 1,
      anon_sym_LBRACK,
    ACTIONS(86), 1,
      sym_text,
    STATE(8), 7,
      sym__inline,
      sym_bolditalic,
      sym_bold,
      sym_italic,
      sym_inline_code,
      sym_link,
      aux_sym_list_item_repeat1,
  [336] = 4,
    ACTIONS(88), 1,
      ts_builtin_sym_end,
    ACTIONS(90), 1,
      anon_sym_AT_AT,
    STATE(10), 2,
      sym_article_header,
      aux_sym_document_repeat1,
    ACTIONS(93), 9,
      anon_sym_LF,
      anon_sym_AT,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      aux_sym_paragraph_start_token1,
  [358] = 4,
    ACTIONS(95), 1,
      ts_builtin_sym_end,
    ACTIONS(99), 1,
      anon_sym_AT,
    STATE(11), 2,
      sym_tag_line,
      aux_sym_document_repeat2,
    ACTIONS(97), 8,
      anon_sym_LF,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      aux_sym_paragraph_start_token1,
  [379] = 3,
    ACTIONS(102), 1,
      ts_builtin_sym_end,
    STATE(14), 2,
      sym_list_item,
      aux_sym_list_repeat1,
    ACTIONS(104), 8,
      anon_sym_LF,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      aux_sym_paragraph_start_token1,
  [397] = 2,
    ACTIONS(106), 1,
      ts_builtin_sym_end,
    ACTIONS(108), 10,
      anon_sym_AT_AT,
      anon_sym_LF,
      anon_sym_AT,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      aux_sym_paragraph_start_token1,
  [413] = 3,
    ACTIONS(110), 1,
      ts_builtin_sym_end,
    STATE(15), 2,
      sym_list_item,
      aux_sym_list_repeat1,
    ACTIONS(112), 8,
      anon_sym_LF,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      aux_sym_paragraph_start_token1,
  [431] = 4,
    ACTIONS(114), 1,
      ts_builtin_sym_end,
    ACTIONS(118), 2,
      anon_sym_DASH,
      sym_ordered_marker,
    STATE(15), 2,
      sym_list_item,
      aux_sym_list_repeat1,
    ACTIONS(116), 6,
      anon_sym_LF,
      sym_heading_marker,
      sym_label_name,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      aux_sym_paragraph_start_token1,
  [451] = 2,
    ACTIONS(121), 1,
      ts_builtin_sym_end,
    ACTIONS(123), 9,
      anon_sym_LF,
      anon_sym_AT,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      aux_sym_paragraph_start_token1,
  [466] = 2,
    ACTIONS(125), 1,
      ts_builtin_sym_end,
    ACTIONS(127), 8,
      anon_sym_LF,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      aux_sym_paragraph_start_token1,
  [480] = 2,
    ACTIONS(129), 1,
      ts_builtin_sym_end,
    ACTIONS(131), 8,
      anon_sym_LF,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      aux_sym_paragraph_start_token1,
  [494] = 2,
    ACTIONS(133), 1,
      ts_builtin_sym_end,
    ACTIONS(135), 8,
      anon_sym_LF,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      aux_sym_paragraph_start_token1,
  [508] = 2,
    ACTIONS(137), 1,
      ts_builtin_sym_end,
    ACTIONS(139), 8,
      anon_sym_LF,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      aux_sym_paragraph_start_token1,
  [522] = 2,
    ACTIONS(141), 1,
      ts_builtin_sym_end,
    ACTIONS(143), 8,
      anon_sym_LF,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      aux_sym_paragraph_start_token1,
  [536] = 2,
    ACTIONS(145), 1,
      ts_builtin_sym_end,
    ACTIONS(147), 8,
      anon_sym_LF,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      aux_sym_paragraph_start_token1,
  [550] = 2,
    ACTIONS(149), 1,
      ts_builtin_sym_end,
    ACTIONS(151), 8,
      anon_sym_LF,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      aux_sym_paragraph_start_token1,
  [564] = 2,
    ACTIONS(153), 1,
      ts_builtin_sym_end,
    ACTIONS(155), 8,
      anon_sym_LF,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      aux_sym_paragraph_start_token1,
  [578] = 2,
    ACTIONS(157), 1,
      ts_builtin_sym_end,
    ACTIONS(159), 8,
      anon_sym_LF,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      aux_sym_paragraph_start_token1,
  [592] = 2,
    ACTIONS(161), 1,
      ts_builtin_sym_end,
    ACTIONS(163), 8,
      anon_sym_LF,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      aux_sym_paragraph_start_token1,
  [606] = 2,
    ACTIONS(165), 1,
      ts_builtin_sym_end,
    ACTIONS(167), 8,
      anon_sym_LF,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      aux_sym_paragraph_start_token1,
  [620] = 2,
    ACTIONS(169), 1,
      ts_builtin_sym_end,
    ACTIONS(171), 8,
      anon_sym_LF,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      aux_sym_paragraph_start_token1,
  [634] = 2,
    ACTIONS(173), 1,
      ts_builtin_sym_end,
    ACTIONS(175), 8,
      anon_sym_LF,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      aux_sym_paragraph_start_token1,
  [648] = 2,
    ACTIONS(179), 1,
      anon_sym_LPAREN,
    ACTIONS(177), 7,
      anon_sym_LF,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [661] = 2,
    ACTIONS(183), 1,
      sym_text,
    ACTIONS(181), 6,
      anon_sym_LF,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
  [673] = 2,
    ACTIONS(187), 1,
      sym_text,
    ACTIONS(185), 6,
      anon_sym_LF,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
  [685] = 2,
    ACTIONS(191), 1,
      sym_text,
    ACTIONS(189), 6,
      anon_sym_LF,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
  [697] = 2,
    ACTIONS(195), 1,
      sym_text,
    ACTIONS(193), 6,
      anon_sym_LF,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
  [709] = 2,
    ACTIONS(199), 1,
      sym_text,
    ACTIONS(197), 6,
      anon_sym_LF,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
  [721] = 4,
    ACTIONS(201), 1,
      anon_sym_LF,
    ACTIONS(203), 1,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
    ACTIONS(205), 1,
      aux_sym_code_line_token1,
    STATE(40), 2,
      sym_code_line,
      aux_sym_code_block_repeat1,
  [735] = 4,
    ACTIONS(205), 1,
      aux_sym_code_line_token1,
    ACTIONS(207), 1,
      anon_sym_LF,
    ACTIONS(209), 1,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
    STATE(41), 2,
      sym_code_line,
      aux_sym_code_block_repeat1,
  [749] = 4,
    ACTIONS(211), 1,
      anon_sym_LF,
    ACTIONS(213), 1,
      aux_sym_code_line_token1,
    ACTIONS(215), 1,
      anon_sym_DOLLAR_DOLLAR,
    STATE(43), 2,
      sym_code_line,
      aux_sym_code_block_repeat1,
  [763] = 4,
    ACTIONS(205), 1,
      aux_sym_code_line_token1,
    ACTIONS(217), 1,
      anon_sym_LF,
    ACTIONS(219), 1,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
    STATE(36), 2,
      sym_code_line,
      aux_sym_code_block_repeat1,
  [777] = 4,
    ACTIONS(221), 1,
      anon_sym_LF,
    ACTIONS(224), 1,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
    ACTIONS(226), 1,
      aux_sym_code_line_token1,
    STATE(40), 2,
      sym_code_line,
      aux_sym_code_block_repeat1,
  [791] = 4,
    ACTIONS(201), 1,
      anon_sym_LF,
    ACTIONS(205), 1,
      aux_sym_code_line_token1,
    ACTIONS(229), 1,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
    STATE(40), 2,
      sym_code_line,
      aux_sym_code_block_repeat1,
  [805] = 4,
    ACTIONS(213), 1,
      aux_sym_code_line_token1,
    ACTIONS(231), 1,
      anon_sym_LF,
    ACTIONS(233), 1,
      anon_sym_DOLLAR_DOLLAR,
    STATE(38), 2,
      sym_code_line,
      aux_sym_code_block_repeat1,
  [819] = 4,
    ACTIONS(224), 1,
      anon_sym_DOLLAR_DOLLAR,
    ACTIONS(235), 1,
      anon_sym_LF,
    ACTIONS(238), 1,
      aux_sym_code_line_token1,
    STATE(43), 2,
      sym_code_line,
      aux_sym_code_block_repeat1,
  [833] = 4,
    ACTIONS(241), 1,
      anon_sym_LF,
    ACTIONS(243), 1,
      aux_sym_paragraph_start_token1,
    STATE(46), 1,
      aux_sym_paragraph_repeat1,
    STATE(74), 1,
      sym_paragraph_line,
  [846] = 4,
    ACTIONS(243), 1,
      aux_sym_paragraph_start_token1,
    ACTIONS(245), 1,
      anon_sym_LF,
    STATE(44), 1,
      aux_sym_paragraph_repeat1,
    STATE(74), 1,
      sym_paragraph_line,
  [859] = 4,
    ACTIONS(247), 1,
      anon_sym_LF,
    ACTIONS(249), 1,
      aux_sym_paragraph_start_token1,
    STATE(46), 1,
      aux_sym_paragraph_repeat1,
    STATE(74), 1,
      sym_paragraph_line,
  [872] = 1,
    ACTIONS(252), 3,
      anon_sym_LF,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      aux_sym_code_line_token1,
  [878] = 3,
    ACTIONS(254), 1,
      anon_sym_STAR_STAR_STAR,
    ACTIONS(256), 1,
      sym_text,
    STATE(51), 1,
      aux_sym_bolditalic_repeat1,
  [888] = 3,
    ACTIONS(258), 1,
      anon_sym_STAR_STAR,
    ACTIONS(260), 1,
      sym_text,
    STATE(53), 1,
      aux_sym_bolditalic_repeat1,
  [898] = 3,
    ACTIONS(262), 1,
      anon_sym_STAR,
    ACTIONS(264), 1,
      sym_text,
    STATE(54), 1,
      aux_sym_bolditalic_repeat1,
  [908] = 3,
    ACTIONS(266), 1,
      anon_sym_STAR_STAR_STAR,
    ACTIONS(268), 1,
      sym_text,
    STATE(51), 1,
      aux_sym_bolditalic_repeat1,
  [918] = 1,
    ACTIONS(252), 3,
      anon_sym_LF,
      aux_sym_code_line_token1,
      anon_sym_DOLLAR_DOLLAR,
  [924] = 3,
    ACTIONS(266), 1,
      anon_sym_STAR_STAR,
    ACTIONS(271), 1,
      sym_text,
    STATE(53), 1,
      aux_sym_bolditalic_repeat1,
  [934] = 3,
    ACTIONS(266), 1,
      anon_sym_STAR,
    ACTIONS(274), 1,
      sym_text,
    STATE(54), 1,
      aux_sym_bolditalic_repeat1,
  [944] = 2,
    ACTIONS(277), 1,
      anon_sym_LF,
    ACTIONS(279), 1,
      aux_sym_code_block_token1,
  [951] = 2,
    ACTIONS(281), 1,
      sym_text,
    STATE(48), 1,
      aux_sym_bolditalic_repeat1,
  [958] = 2,
    ACTIONS(283), 1,
      sym_text,
    STATE(49), 1,
      aux_sym_bolditalic_repeat1,
  [965] = 2,
    ACTIONS(285), 1,
      sym_text,
    STATE(50), 1,
      aux_sym_bolditalic_repeat1,
  [972] = 1,
    ACTIONS(287), 2,
      anon_sym_LF,
      aux_sym_paragraph_start_token1,
  [977] = 2,
    ACTIONS(289), 1,
      aux_sym_code_line_token1,
    STATE(78), 1,
      sym_line_content,
  [984] = 2,
    ACTIONS(289), 1,
      aux_sym_code_line_token1,
    STATE(81), 1,
      sym_line_content,
  [991] = 1,
    ACTIONS(247), 2,
      anon_sym_LF,
      aux_sym_paragraph_start_token1,
  [996] = 2,
    ACTIONS(289), 1,
      aux_sym_code_line_token1,
    STATE(80), 1,
      sym_line_content,
  [1003] = 1,
    ACTIONS(291), 1,
      anon_sym_RBRACK,
  [1007] = 1,
    ACTIONS(293), 1,
      anon_sym_COLON,
  [1011] = 1,
    ACTIONS(295), 1,
      aux_sym_inline_code_token1,
  [1015] = 1,
    ACTIONS(297), 1,
      anon_sym_BQUOTE,
  [1019] = 1,
    ACTIONS(299), 1,
      anon_sym_LF,
  [1023] = 1,
    ACTIONS(301), 1,
      ts_builtin_sym_end,
  [1027] = 1,
    ACTIONS(303), 1,
      aux_sym_link_token1,
  [1031] = 1,
    ACTIONS(305), 1,
      anon_sym_LF,
  [1035] = 1,
    ACTIONS(307), 1,
      anon_sym_LF,
  [1039] = 1,
    ACTIONS(309), 1,
      anon_sym_SPACE,
  [1043] = 1,
    ACTIONS(311), 1,
      anon_sym_LF,
  [1047] = 1,
    ACTIONS(313), 1,
      aux_sym_link_token2,
  [1051] = 1,
    ACTIONS(315), 1,
      anon_sym_RPAREN,
  [1055] = 1,
    ACTIONS(317), 1,
      anon_sym_LF,
  [1059] = 1,
    ACTIONS(319), 1,
      anon_sym_LF,
  [1063] = 1,
    ACTIONS(321), 1,
      anon_sym_LF,
  [1067] = 1,
    ACTIONS(323), 1,
      anon_sym_LF,
  [1071] = 1,
    ACTIONS(325), 1,
      anon_sym_LF,
};

static const uint32_t ts_small_parse_table_map[] = {
  [SMALL_STATE(2)] = 0,
  [SMALL_STATE(3)] = 59,
  [SMALL_STATE(4)] = 111,
  [SMALL_STATE(5)] = 156,
  [SMALL_STATE(6)] = 201,
  [SMALL_STATE(7)] = 246,
  [SMALL_STATE(8)] = 277,
  [SMALL_STATE(9)] = 308,
  [SMALL_STATE(10)] = 336,
  [SMALL_STATE(11)] = 358,
  [SMALL_STATE(12)] = 379,
  [SMALL_STATE(13)] = 397,
  [SMALL_STATE(14)] = 413,
  [SMALL_STATE(15)] = 431,
  [SMALL_STATE(16)] = 451,
  [SMALL_STATE(17)] = 466,
  [SMALL_STATE(18)] = 480,
  [SMALL_STATE(19)] = 494,
  [SMALL_STATE(20)] = 508,
  [SMALL_STATE(21)] = 522,
  [SMALL_STATE(22)] = 536,
  [SMALL_STATE(23)] = 550,
  [SMALL_STATE(24)] = 564,
  [SMALL_STATE(25)] = 578,
  [SMALL_STATE(26)] = 592,
  [SMALL_STATE(27)] = 606,
  [SMALL_STATE(28)] = 620,
  [SMALL_STATE(29)] = 634,
  [SMALL_STATE(30)] = 648,
  [SMALL_STATE(31)] = 661,
  [SMALL_STATE(32)] = 673,
  [SMALL_STATE(33)] = 685,
  [SMALL_STATE(34)] = 697,
  [SMALL_STATE(35)] = 709,
  [SMALL_STATE(36)] = 721,
  [SMALL_STATE(37)] = 735,
  [SMALL_STATE(38)] = 749,
  [SMALL_STATE(39)] = 763,
  [SMALL_STATE(40)] = 777,
  [SMALL_STATE(41)] = 791,
  [SMALL_STATE(42)] = 805,
  [SMALL_STATE(43)] = 819,
  [SMALL_STATE(44)] = 833,
  [SMALL_STATE(45)] = 846,
  [SMALL_STATE(46)] = 859,
  [SMALL_STATE(47)] = 872,
  [SMALL_STATE(48)] = 878,
  [SMALL_STATE(49)] = 888,
  [SMALL_STATE(50)] = 898,
  [SMALL_STATE(51)] = 908,
  [SMALL_STATE(52)] = 918,
  [SMALL_STATE(53)] = 924,
  [SMALL_STATE(54)] = 934,
  [SMALL_STATE(55)] = 944,
  [SMALL_STATE(56)] = 951,
  [SMALL_STATE(57)] = 958,
  [SMALL_STATE(58)] = 965,
  [SMALL_STATE(59)] = 972,
  [SMALL_STATE(60)] = 977,
  [SMALL_STATE(61)] = 984,
  [SMALL_STATE(62)] = 991,
  [SMALL_STATE(63)] = 996,
  [SMALL_STATE(64)] = 1003,
  [SMALL_STATE(65)] = 1007,
  [SMALL_STATE(66)] = 1011,
  [SMALL_STATE(67)] = 1015,
  [SMALL_STATE(68)] = 1019,
  [SMALL_STATE(69)] = 1023,
  [SMALL_STATE(70)] = 1027,
  [SMALL_STATE(71)] = 1031,
  [SMALL_STATE(72)] = 1035,
  [SMALL_STATE(73)] = 1039,
  [SMALL_STATE(74)] = 1043,
  [SMALL_STATE(75)] = 1047,
  [SMALL_STATE(76)] = 1051,
  [SMALL_STATE(77)] = 1055,
  [SMALL_STATE(78)] = 1059,
  [SMALL_STATE(79)] = 1063,
  [SMALL_STATE(80)] = 1067,
  [SMALL_STATE(81)] = 1071,
};

static const TSParseActionEntry ts_parse_actions[] = {
  [0] = {.entry = {.count = 0, .reusable = false}},
  [1] = {.entry = {.count = 1, .reusable = false}}, RECOVER(),
  [3] = {.entry = {.count = 1, .reusable = true}}, SHIFT(61),
  [5] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_document, 1, 0, 0),
  [7] = {.entry = {.count = 1, .reusable = false}}, SHIFT(61),
  [9] = {.entry = {.count = 1, .reusable = false}}, SHIFT(17),
  [11] = {.entry = {.count = 1, .reusable = false}}, SHIFT(60),
  [13] = {.entry = {.count = 1, .reusable = false}}, SHIFT(63),
  [15] = {.entry = {.count = 1, .reusable = false}}, SHIFT(65),
  [17] = {.entry = {.count = 1, .reusable = false}}, SHIFT(73),
  [19] = {.entry = {.count = 1, .reusable = false}}, SHIFT(55),
  [21] = {.entry = {.count = 1, .reusable = false}}, SHIFT(72),
  [23] = {.entry = {.count = 1, .reusable = false}}, SHIFT(59),
  [25] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_document, 2, 0, 0),
  [27] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_document, 3, 0, 0),
  [29] = {.entry = {.count = 1, .reusable = true}}, REDUCE(aux_sym_document_repeat3, 2, 0, 0),
  [31] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_document_repeat3, 2, 0, 0), SHIFT_REPEAT(17),
  [34] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_document_repeat3, 2, 0, 0), SHIFT_REPEAT(63),
  [37] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_document_repeat3, 2, 0, 0), SHIFT_REPEAT(65),
  [40] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_document_repeat3, 2, 0, 0), SHIFT_REPEAT(73),
  [43] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_document_repeat3, 2, 0, 0), SHIFT_REPEAT(55),
  [46] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_document_repeat3, 2, 0, 0), SHIFT_REPEAT(72),
  [49] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_document_repeat3, 2, 0, 0), SHIFT_REPEAT(59),
  [52] = {.entry = {.count = 1, .reusable = false}}, REDUCE(aux_sym_list_item_repeat1, 2, 0, 0),
  [54] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_list_item_repeat1, 2, 0, 0), SHIFT_REPEAT(56),
  [57] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_list_item_repeat1, 2, 0, 0), SHIFT_REPEAT(57),
  [60] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_list_item_repeat1, 2, 0, 0), SHIFT_REPEAT(58),
  [63] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_list_item_repeat1, 2, 0, 0), SHIFT_REPEAT(66),
  [66] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_list_item_repeat1, 2, 0, 0), SHIFT_REPEAT(70),
  [69] = {.entry = {.count = 2, .reusable = true}}, REDUCE(aux_sym_list_item_repeat1, 2, 0, 0), SHIFT_REPEAT(7),
  [72] = {.entry = {.count = 1, .reusable = false}}, SHIFT(24),
  [74] = {.entry = {.count = 1, .reusable = false}}, SHIFT(56),
  [76] = {.entry = {.count = 1, .reusable = false}}, SHIFT(57),
  [78] = {.entry = {.count = 1, .reusable = false}}, SHIFT(58),
  [80] = {.entry = {.count = 1, .reusable = false}}, SHIFT(66),
  [82] = {.entry = {.count = 1, .reusable = false}}, SHIFT(70),
  [84] = {.entry = {.count = 1, .reusable = true}}, SHIFT(7),
  [86] = {.entry = {.count = 1, .reusable = true}}, SHIFT(8),
  [88] = {.entry = {.count = 1, .reusable = true}}, REDUCE(aux_sym_document_repeat1, 2, 0, 0),
  [90] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_document_repeat1, 2, 0, 0), SHIFT_REPEAT(61),
  [93] = {.entry = {.count = 1, .reusable = false}}, REDUCE(aux_sym_document_repeat1, 2, 0, 0),
  [95] = {.entry = {.count = 1, .reusable = true}}, REDUCE(aux_sym_document_repeat2, 2, 0, 0),
  [97] = {.entry = {.count = 1, .reusable = false}}, REDUCE(aux_sym_document_repeat2, 2, 0, 0),
  [99] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_document_repeat2, 2, 0, 0), SHIFT_REPEAT(60),
  [102] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_list, 1, 0, 0),
  [104] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_list, 1, 0, 0),
  [106] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_article_header, 3, 0, 1),
  [108] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_article_header, 3, 0, 1),
  [110] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_list, 2, 0, 0),
  [112] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_list, 2, 0, 0),
  [114] = {.entry = {.count = 1, .reusable = true}}, REDUCE(aux_sym_list_repeat1, 2, 0, 0),
  [116] = {.entry = {.count = 1, .reusable = false}}, REDUCE(aux_sym_list_repeat1, 2, 0, 0),
  [118] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_list_repeat1, 2, 0, 0), SHIFT_REPEAT(73),
  [121] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_tag_line, 3, 0, 1),
  [123] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_tag_line, 3, 0, 1),
  [125] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_blank_line, 1, 0, 0),
  [127] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_blank_line, 1, 0, 0),
  [129] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_block, 1, 0, 0),
  [131] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_block, 1, 0, 0),
  [133] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_paragraph, 2, 0, 0),
  [135] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_paragraph, 2, 0, 0),
  [137] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_code_block, 3, 0, 0),
  [139] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_code_block, 3, 0, 0),
  [141] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_latex_block, 3, 0, 0),
  [143] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_latex_block, 3, 0, 0),
  [145] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_heading, 3, 0, 2),
  [147] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_heading, 3, 0, 2),
  [149] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_paragraph, 3, 0, 0),
  [151] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_paragraph, 3, 0, 0),
  [153] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_list_item, 4, 0, 4),
  [155] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_list_item, 4, 0, 4),
  [157] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_label, 3, 0, 3),
  [159] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_label, 3, 0, 3),
  [161] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_code_block, 4, 0, 5),
  [163] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_code_block, 4, 0, 5),
  [165] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_code_block, 4, 0, 6),
  [167] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_code_block, 4, 0, 6),
  [169] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_latex_block, 4, 0, 5),
  [171] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_latex_block, 4, 0, 5),
  [173] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_code_block, 5, 0, 8),
  [175] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_code_block, 5, 0, 8),
  [177] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_link, 3, 0, 7),
  [179] = {.entry = {.count = 1, .reusable = false}}, SHIFT(75),
  [181] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_link, 6, 0, 9),
  [183] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_link, 6, 0, 9),
  [185] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_bolditalic, 3, 0, 0),
  [187] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_bolditalic, 3, 0, 0),
  [189] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_inline_code, 3, 0, 0),
  [191] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_inline_code, 3, 0, 0),
  [193] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_bold, 3, 0, 0),
  [195] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_bold, 3, 0, 0),
  [197] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_italic, 3, 0, 0),
  [199] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_italic, 3, 0, 0),
  [201] = {.entry = {.count = 1, .reusable = false}}, SHIFT(40),
  [203] = {.entry = {.count = 1, .reusable = false}}, SHIFT(26),
  [205] = {.entry = {.count = 1, .reusable = false}}, SHIFT(47),
  [207] = {.entry = {.count = 1, .reusable = false}}, SHIFT(41),
  [209] = {.entry = {.count = 1, .reusable = false}}, SHIFT(27),
  [211] = {.entry = {.count = 1, .reusable = false}}, SHIFT(43),
  [213] = {.entry = {.count = 1, .reusable = false}}, SHIFT(52),
  [215] = {.entry = {.count = 1, .reusable = false}}, SHIFT(28),
  [217] = {.entry = {.count = 1, .reusable = false}}, SHIFT(36),
  [219] = {.entry = {.count = 1, .reusable = false}}, SHIFT(20),
  [221] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_code_block_repeat1, 2, 0, 0), SHIFT_REPEAT(40),
  [224] = {.entry = {.count = 1, .reusable = false}}, REDUCE(aux_sym_code_block_repeat1, 2, 0, 0),
  [226] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_code_block_repeat1, 2, 0, 0), SHIFT_REPEAT(47),
  [229] = {.entry = {.count = 1, .reusable = false}}, SHIFT(29),
  [231] = {.entry = {.count = 1, .reusable = false}}, SHIFT(38),
  [233] = {.entry = {.count = 1, .reusable = false}}, SHIFT(21),
  [235] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_code_block_repeat1, 2, 0, 0), SHIFT_REPEAT(43),
  [238] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_code_block_repeat1, 2, 0, 0), SHIFT_REPEAT(52),
  [241] = {.entry = {.count = 1, .reusable = false}}, SHIFT(23),
  [243] = {.entry = {.count = 1, .reusable = false}}, SHIFT(77),
  [245] = {.entry = {.count = 1, .reusable = false}}, SHIFT(19),
  [247] = {.entry = {.count = 1, .reusable = false}}, REDUCE(aux_sym_paragraph_repeat1, 2, 0, 0),
  [249] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_paragraph_repeat1, 2, 0, 0), SHIFT_REPEAT(77),
  [252] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_code_line, 1, 0, 0),
  [254] = {.entry = {.count = 1, .reusable = false}}, SHIFT(32),
  [256] = {.entry = {.count = 1, .reusable = true}}, SHIFT(51),
  [258] = {.entry = {.count = 1, .reusable = false}}, SHIFT(34),
  [260] = {.entry = {.count = 1, .reusable = true}}, SHIFT(53),
  [262] = {.entry = {.count = 1, .reusable = false}}, SHIFT(35),
  [264] = {.entry = {.count = 1, .reusable = true}}, SHIFT(54),
  [266] = {.entry = {.count = 1, .reusable = false}}, REDUCE(aux_sym_bolditalic_repeat1, 2, 0, 0),
  [268] = {.entry = {.count = 2, .reusable = true}}, REDUCE(aux_sym_bolditalic_repeat1, 2, 0, 0), SHIFT_REPEAT(51),
  [271] = {.entry = {.count = 2, .reusable = true}}, REDUCE(aux_sym_bolditalic_repeat1, 2, 0, 0), SHIFT_REPEAT(53),
  [274] = {.entry = {.count = 2, .reusable = true}}, REDUCE(aux_sym_bolditalic_repeat1, 2, 0, 0), SHIFT_REPEAT(54),
  [277] = {.entry = {.count = 1, .reusable = true}}, SHIFT(39),
  [279] = {.entry = {.count = 1, .reusable = true}}, SHIFT(68),
  [281] = {.entry = {.count = 1, .reusable = true}}, SHIFT(48),
  [283] = {.entry = {.count = 1, .reusable = true}}, SHIFT(49),
  [285] = {.entry = {.count = 1, .reusable = true}}, SHIFT(50),
  [287] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_paragraph_start, 1, 0, 0),
  [289] = {.entry = {.count = 1, .reusable = true}}, SHIFT(79),
  [291] = {.entry = {.count = 1, .reusable = true}}, SHIFT(30),
  [293] = {.entry = {.count = 1, .reusable = true}}, SHIFT(71),
  [295] = {.entry = {.count = 1, .reusable = true}}, SHIFT(67),
  [297] = {.entry = {.count = 1, .reusable = true}}, SHIFT(33),
  [299] = {.entry = {.count = 1, .reusable = true}}, SHIFT(37),
  [301] = {.entry = {.count = 1, .reusable = true}},  ACCEPT_INPUT(),
  [303] = {.entry = {.count = 1, .reusable = true}}, SHIFT(64),
  [305] = {.entry = {.count = 1, .reusable = true}}, SHIFT(25),
  [307] = {.entry = {.count = 1, .reusable = true}}, SHIFT(42),
  [309] = {.entry = {.count = 1, .reusable = true}}, SHIFT(9),
  [311] = {.entry = {.count = 1, .reusable = true}}, SHIFT(62),
  [313] = {.entry = {.count = 1, .reusable = true}}, SHIFT(76),
  [315] = {.entry = {.count = 1, .reusable = true}}, SHIFT(31),
  [317] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_paragraph_line, 1, 0, 0),
  [319] = {.entry = {.count = 1, .reusable = true}}, SHIFT(16),
  [321] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_line_content, 1, 0, 0),
  [323] = {.entry = {.count = 1, .reusable = true}}, SHIFT(22),
  [325] = {.entry = {.count = 1, .reusable = true}}, SHIFT(13),
};

#ifdef __cplusplus
extern "C" {
#endif
#ifdef TREE_SITTER_HIDE_SYMBOLS
#define TS_PUBLIC
#elif defined(_WIN32)
#define TS_PUBLIC __declspec(dllexport)
#else
#define TS_PUBLIC __attribute__((visibility("default")))
#endif

TS_PUBLIC const TSLanguage *tree_sitter_zortex(void) {
  static const TSLanguage language = {
    .version = LANGUAGE_VERSION,
    .symbol_count = SYMBOL_COUNT,
    .alias_count = ALIAS_COUNT,
    .token_count = TOKEN_COUNT,
    .external_token_count = EXTERNAL_TOKEN_COUNT,
    .state_count = STATE_COUNT,
    .large_state_count = LARGE_STATE_COUNT,
    .production_id_count = PRODUCTION_ID_COUNT,
    .field_count = FIELD_COUNT,
    .max_alias_sequence_length = MAX_ALIAS_SEQUENCE_LENGTH,
    .parse_table = &ts_parse_table[0][0],
    .small_parse_table = ts_small_parse_table,
    .small_parse_table_map = ts_small_parse_table_map,
    .parse_actions = ts_parse_actions,
    .symbol_names = ts_symbol_names,
    .field_names = ts_field_names,
    .field_map_slices = ts_field_map_slices,
    .field_map_entries = ts_field_map_entries,
    .symbol_metadata = ts_symbol_metadata,
    .public_symbol_map = ts_symbol_map,
    .alias_map = ts_non_terminal_alias_map,
    .alias_sequences = &ts_alias_sequences[0][0],
    .lex_modes = ts_lex_modes,
    .lex_fn = ts_lex,
    .primary_state_ids = ts_primary_state_ids,
  };
  return &language;
}
#ifdef __cplusplus
}
#endif
