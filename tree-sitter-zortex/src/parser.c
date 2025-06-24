#include "tree_sitter/parser.h"

#if defined(__GNUC__) || defined(__clang__)
#pragma GCC diagnostic ignored "-Wmissing-field-initializers"
#endif

#define LANGUAGE_VERSION 14
#define STATE_COUNT 106
#define LARGE_STATE_COUNT 10
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
  sym_tag_name = 4,
  sym_heading_marker = 5,
  anon_sym_COLON = 6,
  sym_label_name = 7,
  anon_sym_DASH = 8,
  anon_sym_SPACE = 9,
  sym_ordered_marker = 10,
  anon_sym_BQUOTE_BQUOTE_BQUOTE = 11,
  aux_sym_code_block_token1 = 12,
  aux_sym_code_line_token1 = 13,
  anon_sym_DOLLAR_DOLLAR = 14,
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
  sym_tags = 29,
  sym_tag_line = 30,
  sym_block = 31,
  sym_heading = 32,
  sym_label = 33,
  sym_list = 34,
  sym_list_item = 35,
  sym_code_block = 36,
  sym_code_line = 37,
  sym_latex_block = 38,
  sym_paragraph = 39,
  sym__inline = 40,
  sym_bolditalic = 41,
  sym_bold = 42,
  sym_italic = 43,
  sym_inline_code = 44,
  sym_link = 45,
  sym_line_content = 46,
  sym_blank_line = 47,
  aux_sym_document_repeat1 = 48,
  aux_sym_document_repeat2 = 49,
  aux_sym_document_repeat3 = 50,
  aux_sym_tags_repeat1 = 51,
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
  [sym_tag_name] = "tag_name",
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
  [sym_tags] = "tags",
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
  [aux_sym_tags_repeat1] = "tags_repeat1",
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
  [sym_tag_name] = sym_tag_name,
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
  [sym_tags] = sym_tags,
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
  [aux_sym_tags_repeat1] = aux_sym_tags_repeat1,
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
  [sym_tag_name] = {
    .visible = true,
    .named = true,
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
  [sym_tags] = {
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
  [aux_sym_tags_repeat1] = {
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
    {field_text, 1},
  [5] =
    {field_marker, 0},
  [6] =
    {field_content, 2},
  [7] =
    {field_language, 1},
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
  [37] = 11,
  [38] = 38,
  [39] = 39,
  [40] = 40,
  [41] = 41,
  [42] = 42,
  [43] = 43,
  [44] = 44,
  [45] = 45,
  [46] = 46,
  [47] = 47,
  [48] = 48,
  [49] = 21,
  [50] = 30,
  [51] = 26,
  [52] = 28,
  [53] = 29,
  [54] = 36,
  [55] = 55,
  [56] = 56,
  [57] = 57,
  [58] = 58,
  [59] = 59,
  [60] = 60,
  [61] = 61,
  [62] = 61,
  [63] = 63,
  [64] = 64,
  [65] = 65,
  [66] = 66,
  [67] = 67,
  [68] = 67,
  [69] = 66,
  [70] = 65,
  [71] = 66,
  [72] = 63,
  [73] = 64,
  [74] = 74,
  [75] = 75,
  [76] = 76,
  [77] = 77,
  [78] = 74,
  [79] = 79,
  [80] = 80,
  [81] = 76,
  [82] = 79,
  [83] = 83,
  [84] = 84,
  [85] = 85,
  [86] = 86,
  [87] = 87,
  [88] = 88,
  [89] = 89,
  [90] = 90,
  [91] = 91,
  [92] = 92,
  [93] = 93,
  [94] = 94,
  [95] = 95,
  [96] = 96,
  [97] = 94,
  [98] = 98,
  [99] = 84,
  [100] = 100,
  [101] = 98,
  [102] = 102,
  [103] = 85,
  [104] = 89,
  [105] = 96,
};

static bool ts_lex(TSLexer *lexer, TSStateId state) {
  START_LEXER();
  eof = lexer->eof(lexer);
  switch (state) {
    case 0:
      if (eof) ADVANCE(21);
      ADVANCE_MAP(
        '\n', 24,
        '#', 38,
        '$', 7,
        '(', 80,
        ')', 84,
        '*', 71,
        '-', 48,
        ':', 41,
        '@', 25,
        '[', 76,
        ']', 79,
        '`', 73,
      );
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') SKIP(0);
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(55);
      if (('A' <= lookahead && lookahead <= 'Z') ||
          ('_' <= lookahead && lookahead <= 'z')) ADVANCE(56);
      END_STATE();
    case 1:
      if (lookahead == '\n') ADVANCE(24);
      if (lookahead == '$') ADVANCE(58);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(57);
      if (lookahead != 0) ADVANCE(63);
      END_STATE();
    case 2:
      ADVANCE_MAP(
        '\n', 24,
        '(', 81,
        '*', 71,
        '[', 76,
        '`', 72,
        '\t', 90,
        '\f', 90,
        '\r', 90,
        ' ', 90,
      );
      if (lookahead != 0 &&
          lookahead != ']') ADVANCE(92);
      END_STATE();
    case 3:
      if (lookahead == '\n') ADVANCE(24);
      if (lookahead == '*') ADVANCE(71);
      if (lookahead == '[') ADVANCE(76);
      if (lookahead == '`') ADVANCE(72);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(91);
      if (lookahead != 0 &&
          lookahead != ']') ADVANCE(92);
      END_STATE();
    case 4:
      if (lookahead == '\n') ADVANCE(24);
      if (lookahead == '`') ADVANCE(72);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') SKIP(4);
      if (lookahead == '-' ||
          ('0' <= lookahead && lookahead <= '9') ||
          ('A' <= lookahead && lookahead <= 'Z') ||
          ('_' <= lookahead && lookahead <= 'z')) ADVANCE(56);
      END_STATE();
    case 5:
      if (lookahead == '\n') ADVANCE(24);
      if (lookahead == '`') ADVANCE(61);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(59);
      if (lookahead != 0) ADVANCE(63);
      END_STATE();
    case 6:
      if (lookahead == ' ') ADVANCE(50);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r') SKIP(6);
      END_STATE();
    case 7:
      if (lookahead == '$') ADVANCE(64);
      END_STATE();
    case 8:
      if (lookahead == '*') ADVANCE(9);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(91);
      if (lookahead != 0 &&
          lookahead != '\t' &&
          lookahead != '\n' &&
          lookahead != '[' &&
          lookahead != ']' &&
          lookahead != '`') ADVANCE(92);
      END_STATE();
    case 9:
      if (lookahead == '*') ADVANCE(68);
      END_STATE();
    case 10:
      if (lookahead == '*') ADVANCE(70);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(91);
      if (lookahead != 0 &&
          lookahead != '\t' &&
          lookahead != '\n' &&
          lookahead != '[' &&
          lookahead != ']' &&
          lookahead != '`') ADVANCE(92);
      END_STATE();
    case 11:
      if (lookahead == '`') ADVANCE(53);
      END_STATE();
    case 12:
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(62);
      if (lookahead != 0 &&
          lookahead != '\t' &&
          lookahead != '\n') ADVANCE(63);
      END_STATE();
    case 13:
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(74);
      if (lookahead != 0 &&
          lookahead != '`') ADVANCE(75);
      END_STATE();
    case 14:
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(77);
      if (lookahead != 0 &&
          lookahead != ']') ADVANCE(78);
      END_STATE();
    case 15:
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(82);
      if (lookahead != 0 &&
          lookahead != ')') ADVANCE(83);
      END_STATE();
    case 16:
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') SKIP(16);
      if (lookahead != 0 &&
          (lookahead < '\t' || '\r' < lookahead)) ADVANCE(28);
      END_STATE();
    case 17:
      if (eof) ADVANCE(21);
      ADVANCE_MAP(
        '\n', 24,
        ' ', 42,
        '#', 39,
        '$', 89,
        '*', 71,
        '-', 49,
        '@', 26,
        '[', 76,
        '`', 73,
        '\t', 85,
        '\f', 85,
        '\r', 85,
      );
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(46);
      if (('A' <= lookahead && lookahead <= 'Z') ||
          ('a' <= lookahead && lookahead <= 'z')) ADVANCE(47);
      if (lookahead != 0 &&
          lookahead != ']') ADVANCE(92);
      END_STATE();
    case 18:
      if (eof) ADVANCE(21);
      ADVANCE_MAP(
        '\n', 24,
        ' ', 43,
        '#', 39,
        '$', 89,
        '*', 71,
        '-', 49,
        '[', 76,
        '`', 73,
        '\t', 86,
        '\f', 86,
        '\r', 86,
      );
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(46);
      if (('A' <= lookahead && lookahead <= 'Z') ||
          ('a' <= lookahead && lookahead <= 'z')) ADVANCE(47);
      if (lookahead != 0 &&
          lookahead != ']') ADVANCE(92);
      END_STATE();
    case 19:
      if (eof) ADVANCE(21);
      ADVANCE_MAP(
        '\n', 24,
        ' ', 44,
        '#', 39,
        '$', 89,
        '(', 81,
        '*', 71,
        '-', 49,
        '[', 76,
        '`', 73,
        '\t', 87,
        '\f', 87,
        '\r', 87,
      );
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(46);
      if (('A' <= lookahead && lookahead <= 'Z') ||
          ('a' <= lookahead && lookahead <= 'z')) ADVANCE(47);
      if (lookahead != 0 &&
          lookahead != ']') ADVANCE(92);
      END_STATE();
    case 20:
      if (eof) ADVANCE(21);
      ADVANCE_MAP(
        '\n', 24,
        ' ', 45,
        '#', 39,
        '$', 89,
        '*', 71,
        '-', 49,
        '@', 27,
        '[', 76,
        '`', 73,
        '\t', 88,
        '\f', 88,
        '\r', 88,
      );
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(46);
      if (('A' <= lookahead && lookahead <= 'Z') ||
          ('a' <= lookahead && lookahead <= 'z')) ADVANCE(47);
      if (lookahead != 0 &&
          lookahead != ']') ADVANCE(92);
      END_STATE();
    case 21:
      ACCEPT_TOKEN(ts_builtin_sym_end);
      END_STATE();
    case 22:
      ACCEPT_TOKEN(anon_sym_AT_AT);
      END_STATE();
    case 23:
      ACCEPT_TOKEN(anon_sym_AT_AT);
      if (lookahead != 0 &&
          lookahead != '\n' &&
          lookahead != '*' &&
          lookahead != '[' &&
          lookahead != ']' &&
          lookahead != '`') ADVANCE(92);
      END_STATE();
    case 24:
      ACCEPT_TOKEN(anon_sym_LF);
      END_STATE();
    case 25:
      ACCEPT_TOKEN(anon_sym_AT);
      if (lookahead == '@') ADVANCE(22);
      END_STATE();
    case 26:
      ACCEPT_TOKEN(anon_sym_AT);
      if (lookahead == '@') ADVANCE(23);
      if (lookahead != 0 &&
          lookahead != '\n' &&
          lookahead != '*' &&
          lookahead != '[' &&
          lookahead != ']' &&
          lookahead != '`') ADVANCE(92);
      END_STATE();
    case 27:
      ACCEPT_TOKEN(anon_sym_AT);
      if (lookahead != 0 &&
          lookahead != '\n' &&
          lookahead != '*' &&
          lookahead != '[' &&
          lookahead != ']' &&
          lookahead != '`') ADVANCE(92);
      END_STATE();
    case 28:
      ACCEPT_TOKEN(sym_tag_name);
      if (lookahead != 0 &&
          (lookahead < '\t' || '\r' < lookahead) &&
          lookahead != ' ') ADVANCE(28);
      END_STATE();
    case 29:
      ACCEPT_TOKEN(sym_heading_marker);
      END_STATE();
    case 30:
      ACCEPT_TOKEN(sym_heading_marker);
      if (lookahead == '#') ADVANCE(29);
      END_STATE();
    case 31:
      ACCEPT_TOKEN(sym_heading_marker);
      if (lookahead == '#') ADVANCE(40);
      if (lookahead != 0 &&
          lookahead != '\n' &&
          lookahead != '*' &&
          lookahead != '[' &&
          lookahead != ']' &&
          lookahead != '`') ADVANCE(92);
      END_STATE();
    case 32:
      ACCEPT_TOKEN(sym_heading_marker);
      if (lookahead == '#') ADVANCE(30);
      END_STATE();
    case 33:
      ACCEPT_TOKEN(sym_heading_marker);
      if (lookahead == '#') ADVANCE(31);
      if (lookahead != 0 &&
          lookahead != '\n' &&
          lookahead != '*' &&
          lookahead != '[' &&
          lookahead != ']' &&
          lookahead != '`') ADVANCE(92);
      END_STATE();
    case 34:
      ACCEPT_TOKEN(sym_heading_marker);
      if (lookahead == '#') ADVANCE(32);
      END_STATE();
    case 35:
      ACCEPT_TOKEN(sym_heading_marker);
      if (lookahead == '#') ADVANCE(33);
      if (lookahead != 0 &&
          lookahead != '\n' &&
          lookahead != '*' &&
          lookahead != '[' &&
          lookahead != ']' &&
          lookahead != '`') ADVANCE(92);
      END_STATE();
    case 36:
      ACCEPT_TOKEN(sym_heading_marker);
      if (lookahead == '#') ADVANCE(34);
      END_STATE();
    case 37:
      ACCEPT_TOKEN(sym_heading_marker);
      if (lookahead == '#') ADVANCE(35);
      if (lookahead != 0 &&
          lookahead != '\n' &&
          lookahead != '*' &&
          lookahead != '[' &&
          lookahead != ']' &&
          lookahead != '`') ADVANCE(92);
      END_STATE();
    case 38:
      ACCEPT_TOKEN(sym_heading_marker);
      if (lookahead == '#') ADVANCE(36);
      END_STATE();
    case 39:
      ACCEPT_TOKEN(sym_heading_marker);
      if (lookahead == '#') ADVANCE(37);
      if (lookahead != 0 &&
          lookahead != '\n' &&
          lookahead != '*' &&
          lookahead != '[' &&
          lookahead != ']' &&
          lookahead != '`') ADVANCE(92);
      END_STATE();
    case 40:
      ACCEPT_TOKEN(sym_heading_marker);
      if (lookahead != 0 &&
          lookahead != '\n' &&
          lookahead != '*' &&
          lookahead != '[' &&
          lookahead != ']' &&
          lookahead != '`') ADVANCE(92);
      END_STATE();
    case 41:
      ACCEPT_TOKEN(anon_sym_COLON);
      END_STATE();
    case 42:
      ACCEPT_TOKEN(sym_label_name);
      if (lookahead == ' ') ADVANCE(42);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r') ADVANCE(85);
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(46);
      if (('A' <= lookahead && lookahead <= 'Z') ||
          ('a' <= lookahead && lookahead <= 'z')) ADVANCE(47);
      END_STATE();
    case 43:
      ACCEPT_TOKEN(sym_label_name);
      if (lookahead == ' ') ADVANCE(43);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r') ADVANCE(86);
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(46);
      if (('A' <= lookahead && lookahead <= 'Z') ||
          ('a' <= lookahead && lookahead <= 'z')) ADVANCE(47);
      END_STATE();
    case 44:
      ACCEPT_TOKEN(sym_label_name);
      if (lookahead == ' ') ADVANCE(44);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r') ADVANCE(87);
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(46);
      if (('A' <= lookahead && lookahead <= 'Z') ||
          ('a' <= lookahead && lookahead <= 'z')) ADVANCE(47);
      END_STATE();
    case 45:
      ACCEPT_TOKEN(sym_label_name);
      if (lookahead == ' ') ADVANCE(45);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r') ADVANCE(88);
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(46);
      if (('A' <= lookahead && lookahead <= 'Z') ||
          ('a' <= lookahead && lookahead <= 'z')) ADVANCE(47);
      END_STATE();
    case 46:
      ACCEPT_TOKEN(sym_label_name);
      if (lookahead == '.') ADVANCE(52);
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(46);
      if (lookahead == ' ' ||
          ('A' <= lookahead && lookahead <= 'Z') ||
          ('a' <= lookahead && lookahead <= 'z')) ADVANCE(47);
      if (lookahead != 0 &&
          lookahead != '\n' &&
          lookahead != '*' &&
          (lookahead < 'A' || '[' < lookahead) &&
          lookahead != ']' &&
          (lookahead < '`' || 'z' < lookahead)) ADVANCE(92);
      END_STATE();
    case 47:
      ACCEPT_TOKEN(sym_label_name);
      if (lookahead == ' ' ||
          ('0' <= lookahead && lookahead <= '9') ||
          ('A' <= lookahead && lookahead <= 'Z') ||
          ('a' <= lookahead && lookahead <= 'z')) ADVANCE(47);
      if (lookahead != 0 &&
          lookahead != '\n' &&
          lookahead != '*' &&
          (lookahead < 'A' || '[' < lookahead) &&
          lookahead != ']' &&
          (lookahead < '`' || 'z' < lookahead)) ADVANCE(92);
      END_STATE();
    case 48:
      ACCEPT_TOKEN(anon_sym_DASH);
      if (lookahead == '-' ||
          ('0' <= lookahead && lookahead <= '9') ||
          ('A' <= lookahead && lookahead <= 'Z') ||
          lookahead == '_' ||
          ('a' <= lookahead && lookahead <= 'z')) ADVANCE(56);
      END_STATE();
    case 49:
      ACCEPT_TOKEN(anon_sym_DASH);
      if (lookahead != 0 &&
          lookahead != '\n' &&
          lookahead != '*' &&
          lookahead != '[' &&
          lookahead != ']' &&
          lookahead != '`') ADVANCE(92);
      END_STATE();
    case 50:
      ACCEPT_TOKEN(anon_sym_SPACE);
      if (lookahead == ' ') ADVANCE(50);
      END_STATE();
    case 51:
      ACCEPT_TOKEN(sym_ordered_marker);
      END_STATE();
    case 52:
      ACCEPT_TOKEN(sym_ordered_marker);
      if (lookahead != 0 &&
          lookahead != '\n' &&
          lookahead != '*' &&
          lookahead != '[' &&
          lookahead != ']' &&
          lookahead != '`') ADVANCE(92);
      END_STATE();
    case 53:
      ACCEPT_TOKEN(anon_sym_BQUOTE_BQUOTE_BQUOTE);
      END_STATE();
    case 54:
      ACCEPT_TOKEN(anon_sym_BQUOTE_BQUOTE_BQUOTE);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(63);
      END_STATE();
    case 55:
      ACCEPT_TOKEN(aux_sym_code_block_token1);
      if (lookahead == '.') ADVANCE(51);
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(55);
      if (lookahead == '-' ||
          ('A' <= lookahead && lookahead <= 'Z') ||
          lookahead == '_' ||
          ('a' <= lookahead && lookahead <= 'z')) ADVANCE(56);
      END_STATE();
    case 56:
      ACCEPT_TOKEN(aux_sym_code_block_token1);
      if (lookahead == '-' ||
          ('0' <= lookahead && lookahead <= '9') ||
          ('A' <= lookahead && lookahead <= 'Z') ||
          lookahead == '_' ||
          ('a' <= lookahead && lookahead <= 'z')) ADVANCE(56);
      END_STATE();
    case 57:
      ACCEPT_TOKEN(aux_sym_code_line_token1);
      if (lookahead == '$') ADVANCE(58);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(57);
      if (lookahead != 0 &&
          lookahead != '\t' &&
          lookahead != '\n') ADVANCE(63);
      END_STATE();
    case 58:
      ACCEPT_TOKEN(aux_sym_code_line_token1);
      if (lookahead == '$') ADVANCE(66);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(63);
      END_STATE();
    case 59:
      ACCEPT_TOKEN(aux_sym_code_line_token1);
      if (lookahead == '`') ADVANCE(61);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(59);
      if (lookahead != 0 &&
          lookahead != '\t' &&
          lookahead != '\n') ADVANCE(63);
      END_STATE();
    case 60:
      ACCEPT_TOKEN(aux_sym_code_line_token1);
      if (lookahead == '`') ADVANCE(54);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(63);
      END_STATE();
    case 61:
      ACCEPT_TOKEN(aux_sym_code_line_token1);
      if (lookahead == '`') ADVANCE(60);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(63);
      END_STATE();
    case 62:
      ACCEPT_TOKEN(aux_sym_code_line_token1);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(62);
      if (lookahead != 0 &&
          lookahead != '\t' &&
          lookahead != '\n') ADVANCE(63);
      END_STATE();
    case 63:
      ACCEPT_TOKEN(aux_sym_code_line_token1);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(63);
      END_STATE();
    case 64:
      ACCEPT_TOKEN(anon_sym_DOLLAR_DOLLAR);
      END_STATE();
    case 65:
      ACCEPT_TOKEN(anon_sym_DOLLAR_DOLLAR);
      if (lookahead != 0 &&
          lookahead != '\n' &&
          lookahead != '*' &&
          lookahead != '[' &&
          lookahead != ']' &&
          lookahead != '`') ADVANCE(92);
      END_STATE();
    case 66:
      ACCEPT_TOKEN(anon_sym_DOLLAR_DOLLAR);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(63);
      END_STATE();
    case 67:
      ACCEPT_TOKEN(anon_sym_STAR_STAR_STAR);
      END_STATE();
    case 68:
      ACCEPT_TOKEN(anon_sym_STAR_STAR);
      END_STATE();
    case 69:
      ACCEPT_TOKEN(anon_sym_STAR_STAR);
      if (lookahead == '*') ADVANCE(67);
      END_STATE();
    case 70:
      ACCEPT_TOKEN(anon_sym_STAR);
      END_STATE();
    case 71:
      ACCEPT_TOKEN(anon_sym_STAR);
      if (lookahead == '*') ADVANCE(69);
      END_STATE();
    case 72:
      ACCEPT_TOKEN(anon_sym_BQUOTE);
      END_STATE();
    case 73:
      ACCEPT_TOKEN(anon_sym_BQUOTE);
      if (lookahead == '`') ADVANCE(11);
      END_STATE();
    case 74:
      ACCEPT_TOKEN(aux_sym_inline_code_token1);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(74);
      if (lookahead != 0 &&
          lookahead != '`') ADVANCE(75);
      END_STATE();
    case 75:
      ACCEPT_TOKEN(aux_sym_inline_code_token1);
      if (lookahead != 0 &&
          lookahead != '`') ADVANCE(75);
      END_STATE();
    case 76:
      ACCEPT_TOKEN(anon_sym_LBRACK);
      END_STATE();
    case 77:
      ACCEPT_TOKEN(aux_sym_link_token1);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(77);
      if (lookahead != 0 &&
          lookahead != ']') ADVANCE(78);
      END_STATE();
    case 78:
      ACCEPT_TOKEN(aux_sym_link_token1);
      if (lookahead != 0 &&
          lookahead != ']') ADVANCE(78);
      END_STATE();
    case 79:
      ACCEPT_TOKEN(anon_sym_RBRACK);
      END_STATE();
    case 80:
      ACCEPT_TOKEN(anon_sym_LPAREN);
      END_STATE();
    case 81:
      ACCEPT_TOKEN(anon_sym_LPAREN);
      if (lookahead != 0 &&
          lookahead != '\n' &&
          lookahead != '*' &&
          lookahead != '[' &&
          lookahead != ']' &&
          lookahead != '`') ADVANCE(92);
      END_STATE();
    case 82:
      ACCEPT_TOKEN(aux_sym_link_token2);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(82);
      if (lookahead != 0 &&
          lookahead != ')') ADVANCE(83);
      END_STATE();
    case 83:
      ACCEPT_TOKEN(aux_sym_link_token2);
      if (lookahead != 0 &&
          lookahead != ')') ADVANCE(83);
      END_STATE();
    case 84:
      ACCEPT_TOKEN(anon_sym_RPAREN);
      END_STATE();
    case 85:
      ACCEPT_TOKEN(sym_text);
      if (lookahead == ' ') ADVANCE(42);
      if (lookahead == '#') ADVANCE(39);
      if (lookahead == '$') ADVANCE(89);
      if (lookahead == '-') ADVANCE(49);
      if (lookahead == '@') ADVANCE(26);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r') ADVANCE(85);
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(46);
      if (('A' <= lookahead && lookahead <= 'Z') ||
          ('a' <= lookahead && lookahead <= 'z')) ADVANCE(47);
      if (lookahead != 0 &&
          lookahead != '\t' &&
          lookahead != '\n' &&
          lookahead != '*' &&
          (lookahead < '@' || '[' < lookahead) &&
          lookahead != ']' &&
          (lookahead < '`' || 'z' < lookahead)) ADVANCE(92);
      END_STATE();
    case 86:
      ACCEPT_TOKEN(sym_text);
      if (lookahead == ' ') ADVANCE(43);
      if (lookahead == '#') ADVANCE(39);
      if (lookahead == '$') ADVANCE(89);
      if (lookahead == '-') ADVANCE(49);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r') ADVANCE(86);
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(46);
      if (('A' <= lookahead && lookahead <= 'Z') ||
          ('a' <= lookahead && lookahead <= 'z')) ADVANCE(47);
      if (lookahead != 0 &&
          lookahead != '\t' &&
          lookahead != '\n' &&
          lookahead != '*' &&
          (lookahead < 'A' || '[' < lookahead) &&
          lookahead != ']' &&
          (lookahead < '`' || 'z' < lookahead)) ADVANCE(92);
      END_STATE();
    case 87:
      ACCEPT_TOKEN(sym_text);
      if (lookahead == ' ') ADVANCE(44);
      if (lookahead == '#') ADVANCE(39);
      if (lookahead == '$') ADVANCE(89);
      if (lookahead == '(') ADVANCE(81);
      if (lookahead == '-') ADVANCE(49);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r') ADVANCE(87);
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(46);
      if (('A' <= lookahead && lookahead <= 'Z') ||
          ('a' <= lookahead && lookahead <= 'z')) ADVANCE(47);
      if (lookahead != 0 &&
          lookahead != '\t' &&
          lookahead != '\n' &&
          lookahead != '*' &&
          (lookahead < 'A' || '[' < lookahead) &&
          lookahead != ']' &&
          (lookahead < '`' || 'z' < lookahead)) ADVANCE(92);
      END_STATE();
    case 88:
      ACCEPT_TOKEN(sym_text);
      if (lookahead == ' ') ADVANCE(45);
      if (lookahead == '#') ADVANCE(39);
      if (lookahead == '$') ADVANCE(89);
      if (lookahead == '-') ADVANCE(49);
      if (lookahead == '@') ADVANCE(27);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r') ADVANCE(88);
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(46);
      if (('A' <= lookahead && lookahead <= 'Z') ||
          ('a' <= lookahead && lookahead <= 'z')) ADVANCE(47);
      if (lookahead != 0 &&
          lookahead != '\t' &&
          lookahead != '\n' &&
          lookahead != '*' &&
          (lookahead < '@' || '[' < lookahead) &&
          lookahead != ']' &&
          (lookahead < '`' || 'z' < lookahead)) ADVANCE(92);
      END_STATE();
    case 89:
      ACCEPT_TOKEN(sym_text);
      if (lookahead == '$') ADVANCE(65);
      if (lookahead != 0 &&
          lookahead != '\n' &&
          lookahead != '*' &&
          lookahead != '[' &&
          lookahead != ']' &&
          lookahead != '`') ADVANCE(92);
      END_STATE();
    case 90:
      ACCEPT_TOKEN(sym_text);
      if (lookahead == '(') ADVANCE(81);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(90);
      if (lookahead != 0 &&
          lookahead != '\t' &&
          lookahead != '\n' &&
          lookahead != '*' &&
          lookahead != '[' &&
          lookahead != ']' &&
          lookahead != '`') ADVANCE(92);
      END_STATE();
    case 91:
      ACCEPT_TOKEN(sym_text);
      if (lookahead == '\t' ||
          lookahead == '\f' ||
          lookahead == '\r' ||
          lookahead == ' ') ADVANCE(91);
      if (lookahead != 0 &&
          lookahead != '\t' &&
          lookahead != '\n' &&
          lookahead != '*' &&
          lookahead != '[' &&
          lookahead != ']' &&
          lookahead != '`') ADVANCE(92);
      END_STATE();
    case 92:
      ACCEPT_TOKEN(sym_text);
      if (lookahead != 0 &&
          lookahead != '\n' &&
          lookahead != '*' &&
          lookahead != '[' &&
          lookahead != ']' &&
          lookahead != '`') ADVANCE(92);
      END_STATE();
    default:
      return false;
  }
}

static const TSLexMode ts_lex_modes[STATE_COUNT] = {
  [0] = {.lex_state = 0},
  [1] = {.lex_state = 0},
  [2] = {.lex_state = 17},
  [3] = {.lex_state = 18},
  [4] = {.lex_state = 18},
  [5] = {.lex_state = 18},
  [6] = {.lex_state = 18},
  [7] = {.lex_state = 18},
  [8] = {.lex_state = 18},
  [9] = {.lex_state = 18},
  [10] = {.lex_state = 18},
  [11] = {.lex_state = 18},
  [12] = {.lex_state = 17},
  [13] = {.lex_state = 20},
  [14] = {.lex_state = 20},
  [15] = {.lex_state = 17},
  [16] = {.lex_state = 18},
  [17] = {.lex_state = 18},
  [18] = {.lex_state = 18},
  [19] = {.lex_state = 20},
  [20] = {.lex_state = 18},
  [21] = {.lex_state = 19},
  [22] = {.lex_state = 18},
  [23] = {.lex_state = 18},
  [24] = {.lex_state = 18},
  [25] = {.lex_state = 3},
  [26] = {.lex_state = 18},
  [27] = {.lex_state = 18},
  [28] = {.lex_state = 18},
  [29] = {.lex_state = 18},
  [30] = {.lex_state = 18},
  [31] = {.lex_state = 18},
  [32] = {.lex_state = 18},
  [33] = {.lex_state = 18},
  [34] = {.lex_state = 18},
  [35] = {.lex_state = 18},
  [36] = {.lex_state = 18},
  [37] = {.lex_state = 3},
  [38] = {.lex_state = 3},
  [39] = {.lex_state = 18},
  [40] = {.lex_state = 18},
  [41] = {.lex_state = 18},
  [42] = {.lex_state = 18},
  [43] = {.lex_state = 18},
  [44] = {.lex_state = 18},
  [45] = {.lex_state = 18},
  [46] = {.lex_state = 18},
  [47] = {.lex_state = 18},
  [48] = {.lex_state = 18},
  [49] = {.lex_state = 2},
  [50] = {.lex_state = 3},
  [51] = {.lex_state = 3},
  [52] = {.lex_state = 3},
  [53] = {.lex_state = 3},
  [54] = {.lex_state = 3},
  [55] = {.lex_state = 1},
  [56] = {.lex_state = 5},
  [57] = {.lex_state = 5},
  [58] = {.lex_state = 5},
  [59] = {.lex_state = 1},
  [60] = {.lex_state = 5},
  [61] = {.lex_state = 5},
  [62] = {.lex_state = 1},
  [63] = {.lex_state = 3},
  [64] = {.lex_state = 8},
  [65] = {.lex_state = 5},
  [66] = {.lex_state = 3},
  [67] = {.lex_state = 10},
  [68] = {.lex_state = 10},
  [69] = {.lex_state = 8},
  [70] = {.lex_state = 1},
  [71] = {.lex_state = 10},
  [72] = {.lex_state = 3},
  [73] = {.lex_state = 8},
  [74] = {.lex_state = 3},
  [75] = {.lex_state = 12},
  [76] = {.lex_state = 3},
  [77] = {.lex_state = 4},
  [78] = {.lex_state = 3},
  [79] = {.lex_state = 3},
  [80] = {.lex_state = 12},
  [81] = {.lex_state = 3},
  [82] = {.lex_state = 3},
  [83] = {.lex_state = 6},
  [84] = {.lex_state = 0},
  [85] = {.lex_state = 13},
  [86] = {.lex_state = 0},
  [87] = {.lex_state = 0},
  [88] = {.lex_state = 0},
  [89] = {.lex_state = 14},
  [90] = {.lex_state = 0},
  [91] = {.lex_state = 0},
  [92] = {.lex_state = 0},
  [93] = {.lex_state = 0},
  [94] = {.lex_state = 4},
  [95] = {.lex_state = 0},
  [96] = {.lex_state = 15},
  [97] = {.lex_state = 4},
  [98] = {.lex_state = 0},
  [99] = {.lex_state = 0},
  [100] = {.lex_state = 0},
  [101] = {.lex_state = 0},
  [102] = {.lex_state = 16},
  [103] = {.lex_state = 13},
  [104] = {.lex_state = 14},
  [105] = {.lex_state = 15},
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
    [anon_sym_BQUOTE_BQUOTE_BQUOTE] = ACTIONS(1),
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
    [sym_document] = STATE(90),
    [sym_article_header] = STATE(2),
    [aux_sym_document_repeat1] = STATE(2),
    [anon_sym_AT_AT] = ACTIONS(3),
  },
  [2] = {
    [sym_article_header] = STATE(12),
    [sym_tags] = STATE(3),
    [sym_tag_line] = STATE(13),
    [sym_block] = STATE(6),
    [sym_heading] = STATE(41),
    [sym_label] = STATE(41),
    [sym_list] = STATE(41),
    [sym_list_item] = STATE(17),
    [sym_code_block] = STATE(41),
    [sym_latex_block] = STATE(41),
    [sym_paragraph] = STATE(41),
    [sym__inline] = STATE(10),
    [sym_bolditalic] = STATE(10),
    [sym_bold] = STATE(10),
    [sym_italic] = STATE(10),
    [sym_inline_code] = STATE(10),
    [sym_link] = STATE(10),
    [sym_blank_line] = STATE(4),
    [aux_sym_document_repeat1] = STATE(12),
    [aux_sym_document_repeat2] = STATE(4),
    [aux_sym_document_repeat3] = STATE(6),
    [aux_sym_tags_repeat1] = STATE(13),
    [aux_sym_list_item_repeat1] = STATE(10),
    [ts_builtin_sym_end] = ACTIONS(5),
    [anon_sym_AT_AT] = ACTIONS(7),
    [anon_sym_LF] = ACTIONS(9),
    [anon_sym_AT] = ACTIONS(11),
    [sym_heading_marker] = ACTIONS(13),
    [sym_label_name] = ACTIONS(15),
    [anon_sym_DASH] = ACTIONS(17),
    [sym_ordered_marker] = ACTIONS(17),
    [anon_sym_BQUOTE_BQUOTE_BQUOTE] = ACTIONS(19),
    [anon_sym_DOLLAR_DOLLAR] = ACTIONS(21),
    [anon_sym_STAR_STAR_STAR] = ACTIONS(23),
    [anon_sym_STAR_STAR] = ACTIONS(25),
    [anon_sym_STAR] = ACTIONS(27),
    [anon_sym_BQUOTE] = ACTIONS(29),
    [anon_sym_LBRACK] = ACTIONS(31),
    [sym_text] = ACTIONS(33),
  },
  [3] = {
    [sym_block] = STATE(7),
    [sym_heading] = STATE(41),
    [sym_label] = STATE(41),
    [sym_list] = STATE(41),
    [sym_list_item] = STATE(17),
    [sym_code_block] = STATE(41),
    [sym_latex_block] = STATE(41),
    [sym_paragraph] = STATE(41),
    [sym__inline] = STATE(10),
    [sym_bolditalic] = STATE(10),
    [sym_bold] = STATE(10),
    [sym_italic] = STATE(10),
    [sym_inline_code] = STATE(10),
    [sym_link] = STATE(10),
    [sym_blank_line] = STATE(5),
    [aux_sym_document_repeat2] = STATE(5),
    [aux_sym_document_repeat3] = STATE(7),
    [aux_sym_list_item_repeat1] = STATE(10),
    [ts_builtin_sym_end] = ACTIONS(35),
    [anon_sym_LF] = ACTIONS(9),
    [sym_heading_marker] = ACTIONS(13),
    [sym_label_name] = ACTIONS(15),
    [anon_sym_DASH] = ACTIONS(17),
    [sym_ordered_marker] = ACTIONS(17),
    [anon_sym_BQUOTE_BQUOTE_BQUOTE] = ACTIONS(19),
    [anon_sym_DOLLAR_DOLLAR] = ACTIONS(21),
    [anon_sym_STAR_STAR_STAR] = ACTIONS(23),
    [anon_sym_STAR_STAR] = ACTIONS(25),
    [anon_sym_STAR] = ACTIONS(27),
    [anon_sym_BQUOTE] = ACTIONS(29),
    [anon_sym_LBRACK] = ACTIONS(31),
    [sym_text] = ACTIONS(33),
  },
  [4] = {
    [sym_block] = STATE(7),
    [sym_heading] = STATE(41),
    [sym_label] = STATE(41),
    [sym_list] = STATE(41),
    [sym_list_item] = STATE(17),
    [sym_code_block] = STATE(41),
    [sym_latex_block] = STATE(41),
    [sym_paragraph] = STATE(41),
    [sym__inline] = STATE(10),
    [sym_bolditalic] = STATE(10),
    [sym_bold] = STATE(10),
    [sym_italic] = STATE(10),
    [sym_inline_code] = STATE(10),
    [sym_link] = STATE(10),
    [sym_blank_line] = STATE(16),
    [aux_sym_document_repeat2] = STATE(16),
    [aux_sym_document_repeat3] = STATE(7),
    [aux_sym_list_item_repeat1] = STATE(10),
    [ts_builtin_sym_end] = ACTIONS(35),
    [anon_sym_LF] = ACTIONS(9),
    [sym_heading_marker] = ACTIONS(13),
    [sym_label_name] = ACTIONS(15),
    [anon_sym_DASH] = ACTIONS(17),
    [sym_ordered_marker] = ACTIONS(17),
    [anon_sym_BQUOTE_BQUOTE_BQUOTE] = ACTIONS(19),
    [anon_sym_DOLLAR_DOLLAR] = ACTIONS(21),
    [anon_sym_STAR_STAR_STAR] = ACTIONS(23),
    [anon_sym_STAR_STAR] = ACTIONS(25),
    [anon_sym_STAR] = ACTIONS(27),
    [anon_sym_BQUOTE] = ACTIONS(29),
    [anon_sym_LBRACK] = ACTIONS(31),
    [sym_text] = ACTIONS(33),
  },
  [5] = {
    [sym_block] = STATE(9),
    [sym_heading] = STATE(41),
    [sym_label] = STATE(41),
    [sym_list] = STATE(41),
    [sym_list_item] = STATE(17),
    [sym_code_block] = STATE(41),
    [sym_latex_block] = STATE(41),
    [sym_paragraph] = STATE(41),
    [sym__inline] = STATE(10),
    [sym_bolditalic] = STATE(10),
    [sym_bold] = STATE(10),
    [sym_italic] = STATE(10),
    [sym_inline_code] = STATE(10),
    [sym_link] = STATE(10),
    [sym_blank_line] = STATE(16),
    [aux_sym_document_repeat2] = STATE(16),
    [aux_sym_document_repeat3] = STATE(9),
    [aux_sym_list_item_repeat1] = STATE(10),
    [ts_builtin_sym_end] = ACTIONS(37),
    [anon_sym_LF] = ACTIONS(9),
    [sym_heading_marker] = ACTIONS(13),
    [sym_label_name] = ACTIONS(15),
    [anon_sym_DASH] = ACTIONS(17),
    [sym_ordered_marker] = ACTIONS(17),
    [anon_sym_BQUOTE_BQUOTE_BQUOTE] = ACTIONS(19),
    [anon_sym_DOLLAR_DOLLAR] = ACTIONS(21),
    [anon_sym_STAR_STAR_STAR] = ACTIONS(23),
    [anon_sym_STAR_STAR] = ACTIONS(25),
    [anon_sym_STAR] = ACTIONS(27),
    [anon_sym_BQUOTE] = ACTIONS(29),
    [anon_sym_LBRACK] = ACTIONS(31),
    [sym_text] = ACTIONS(33),
  },
  [6] = {
    [sym_block] = STATE(8),
    [sym_heading] = STATE(41),
    [sym_label] = STATE(41),
    [sym_list] = STATE(41),
    [sym_list_item] = STATE(17),
    [sym_code_block] = STATE(41),
    [sym_latex_block] = STATE(41),
    [sym_paragraph] = STATE(41),
    [sym__inline] = STATE(10),
    [sym_bolditalic] = STATE(10),
    [sym_bold] = STATE(10),
    [sym_italic] = STATE(10),
    [sym_inline_code] = STATE(10),
    [sym_link] = STATE(10),
    [aux_sym_document_repeat3] = STATE(8),
    [aux_sym_list_item_repeat1] = STATE(10),
    [ts_builtin_sym_end] = ACTIONS(35),
    [sym_heading_marker] = ACTIONS(13),
    [sym_label_name] = ACTIONS(15),
    [anon_sym_DASH] = ACTIONS(17),
    [sym_ordered_marker] = ACTIONS(17),
    [anon_sym_BQUOTE_BQUOTE_BQUOTE] = ACTIONS(19),
    [anon_sym_DOLLAR_DOLLAR] = ACTIONS(21),
    [anon_sym_STAR_STAR_STAR] = ACTIONS(23),
    [anon_sym_STAR_STAR] = ACTIONS(25),
    [anon_sym_STAR] = ACTIONS(27),
    [anon_sym_BQUOTE] = ACTIONS(29),
    [anon_sym_LBRACK] = ACTIONS(31),
    [sym_text] = ACTIONS(33),
  },
  [7] = {
    [sym_block] = STATE(8),
    [sym_heading] = STATE(41),
    [sym_label] = STATE(41),
    [sym_list] = STATE(41),
    [sym_list_item] = STATE(17),
    [sym_code_block] = STATE(41),
    [sym_latex_block] = STATE(41),
    [sym_paragraph] = STATE(41),
    [sym__inline] = STATE(10),
    [sym_bolditalic] = STATE(10),
    [sym_bold] = STATE(10),
    [sym_italic] = STATE(10),
    [sym_inline_code] = STATE(10),
    [sym_link] = STATE(10),
    [aux_sym_document_repeat3] = STATE(8),
    [aux_sym_list_item_repeat1] = STATE(10),
    [ts_builtin_sym_end] = ACTIONS(37),
    [sym_heading_marker] = ACTIONS(13),
    [sym_label_name] = ACTIONS(15),
    [anon_sym_DASH] = ACTIONS(17),
    [sym_ordered_marker] = ACTIONS(17),
    [anon_sym_BQUOTE_BQUOTE_BQUOTE] = ACTIONS(19),
    [anon_sym_DOLLAR_DOLLAR] = ACTIONS(21),
    [anon_sym_STAR_STAR_STAR] = ACTIONS(23),
    [anon_sym_STAR_STAR] = ACTIONS(25),
    [anon_sym_STAR] = ACTIONS(27),
    [anon_sym_BQUOTE] = ACTIONS(29),
    [anon_sym_LBRACK] = ACTIONS(31),
    [sym_text] = ACTIONS(33),
  },
  [8] = {
    [sym_block] = STATE(8),
    [sym_heading] = STATE(41),
    [sym_label] = STATE(41),
    [sym_list] = STATE(41),
    [sym_list_item] = STATE(17),
    [sym_code_block] = STATE(41),
    [sym_latex_block] = STATE(41),
    [sym_paragraph] = STATE(41),
    [sym__inline] = STATE(10),
    [sym_bolditalic] = STATE(10),
    [sym_bold] = STATE(10),
    [sym_italic] = STATE(10),
    [sym_inline_code] = STATE(10),
    [sym_link] = STATE(10),
    [aux_sym_document_repeat3] = STATE(8),
    [aux_sym_list_item_repeat1] = STATE(10),
    [ts_builtin_sym_end] = ACTIONS(39),
    [sym_heading_marker] = ACTIONS(41),
    [sym_label_name] = ACTIONS(44),
    [anon_sym_DASH] = ACTIONS(47),
    [sym_ordered_marker] = ACTIONS(47),
    [anon_sym_BQUOTE_BQUOTE_BQUOTE] = ACTIONS(50),
    [anon_sym_DOLLAR_DOLLAR] = ACTIONS(53),
    [anon_sym_STAR_STAR_STAR] = ACTIONS(56),
    [anon_sym_STAR_STAR] = ACTIONS(59),
    [anon_sym_STAR] = ACTIONS(62),
    [anon_sym_BQUOTE] = ACTIONS(65),
    [anon_sym_LBRACK] = ACTIONS(68),
    [sym_text] = ACTIONS(71),
  },
  [9] = {
    [sym_block] = STATE(8),
    [sym_heading] = STATE(41),
    [sym_label] = STATE(41),
    [sym_list] = STATE(41),
    [sym_list_item] = STATE(17),
    [sym_code_block] = STATE(41),
    [sym_latex_block] = STATE(41),
    [sym_paragraph] = STATE(41),
    [sym__inline] = STATE(10),
    [sym_bolditalic] = STATE(10),
    [sym_bold] = STATE(10),
    [sym_italic] = STATE(10),
    [sym_inline_code] = STATE(10),
    [sym_link] = STATE(10),
    [aux_sym_document_repeat3] = STATE(8),
    [aux_sym_list_item_repeat1] = STATE(10),
    [ts_builtin_sym_end] = ACTIONS(74),
    [sym_heading_marker] = ACTIONS(13),
    [sym_label_name] = ACTIONS(15),
    [anon_sym_DASH] = ACTIONS(17),
    [sym_ordered_marker] = ACTIONS(17),
    [anon_sym_BQUOTE_BQUOTE_BQUOTE] = ACTIONS(19),
    [anon_sym_DOLLAR_DOLLAR] = ACTIONS(21),
    [anon_sym_STAR_STAR_STAR] = ACTIONS(23),
    [anon_sym_STAR_STAR] = ACTIONS(25),
    [anon_sym_STAR] = ACTIONS(27),
    [anon_sym_BQUOTE] = ACTIONS(29),
    [anon_sym_LBRACK] = ACTIONS(31),
    [sym_text] = ACTIONS(33),
  },
};

static const uint16_t ts_small_parse_table[] = {
  [0] = 11,
    ACTIONS(23), 1,
      anon_sym_STAR_STAR_STAR,
    ACTIONS(25), 1,
      anon_sym_STAR_STAR,
    ACTIONS(27), 1,
      anon_sym_STAR,
    ACTIONS(29), 1,
      anon_sym_BQUOTE,
    ACTIONS(31), 1,
      anon_sym_LBRACK,
    ACTIONS(76), 1,
      ts_builtin_sym_end,
    ACTIONS(78), 1,
      anon_sym_LF,
    ACTIONS(82), 1,
      sym_text,
    STATE(20), 1,
      aux_sym_paragraph_repeat1,
    ACTIONS(80), 6,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
    STATE(11), 7,
      sym__inline,
      sym_bolditalic,
      sym_bold,
      sym_italic,
      sym_inline_code,
      sym_link,
      aux_sym_list_item_repeat1,
  [45] = 9,
    ACTIONS(84), 1,
      ts_builtin_sym_end,
    ACTIONS(88), 1,
      anon_sym_STAR_STAR_STAR,
    ACTIONS(91), 1,
      anon_sym_STAR_STAR,
    ACTIONS(94), 1,
      anon_sym_STAR,
    ACTIONS(97), 1,
      anon_sym_BQUOTE,
    ACTIONS(100), 1,
      anon_sym_LBRACK,
    ACTIONS(103), 1,
      sym_text,
    ACTIONS(86), 7,
      anon_sym_LF,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
    STATE(11), 7,
      sym__inline,
      sym_bolditalic,
      sym_bold,
      sym_italic,
      sym_inline_code,
      sym_link,
      aux_sym_list_item_repeat1,
  [85] = 4,
    ACTIONS(106), 1,
      ts_builtin_sym_end,
    ACTIONS(108), 1,
      anon_sym_AT_AT,
    STATE(12), 2,
      sym_article_header,
      aux_sym_document_repeat1,
    ACTIONS(111), 14,
      anon_sym_LF,
      anon_sym_AT,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [112] = 4,
    ACTIONS(11), 1,
      anon_sym_AT,
    ACTIONS(113), 1,
      ts_builtin_sym_end,
    STATE(14), 2,
      sym_tag_line,
      aux_sym_tags_repeat1,
    ACTIONS(115), 13,
      anon_sym_LF,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [138] = 4,
    ACTIONS(117), 1,
      ts_builtin_sym_end,
    ACTIONS(121), 1,
      anon_sym_AT,
    STATE(14), 2,
      sym_tag_line,
      aux_sym_tags_repeat1,
    ACTIONS(119), 13,
      anon_sym_LF,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [164] = 2,
    ACTIONS(124), 1,
      ts_builtin_sym_end,
    ACTIONS(126), 15,
      anon_sym_AT_AT,
      anon_sym_LF,
      anon_sym_AT,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [185] = 4,
    ACTIONS(128), 1,
      ts_builtin_sym_end,
    ACTIONS(130), 1,
      anon_sym_LF,
    STATE(16), 2,
      sym_blank_line,
      aux_sym_document_repeat2,
    ACTIONS(133), 12,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [210] = 3,
    ACTIONS(135), 1,
      ts_builtin_sym_end,
    STATE(18), 2,
      sym_list_item,
      aux_sym_list_repeat1,
    ACTIONS(137), 12,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [232] = 3,
    ACTIONS(139), 1,
      ts_builtin_sym_end,
    STATE(22), 2,
      sym_list_item,
      aux_sym_list_repeat1,
    ACTIONS(141), 12,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [254] = 2,
    ACTIONS(143), 1,
      ts_builtin_sym_end,
    ACTIONS(145), 14,
      anon_sym_LF,
      anon_sym_AT,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [274] = 4,
    ACTIONS(147), 1,
      ts_builtin_sym_end,
    ACTIONS(149), 1,
      anon_sym_LF,
    STATE(23), 1,
      aux_sym_paragraph_repeat1,
    ACTIONS(151), 12,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [298] = 3,
    ACTIONS(153), 1,
      ts_builtin_sym_end,
    ACTIONS(157), 1,
      anon_sym_LPAREN,
    ACTIONS(155), 13,
      anon_sym_LF,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [320] = 4,
    ACTIONS(159), 1,
      ts_builtin_sym_end,
    ACTIONS(163), 2,
      anon_sym_DASH,
      sym_ordered_marker,
    STATE(22), 2,
      sym_list_item,
      aux_sym_list_repeat1,
    ACTIONS(161), 10,
      sym_heading_marker,
      sym_label_name,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [344] = 4,
    ACTIONS(166), 1,
      ts_builtin_sym_end,
    ACTIONS(168), 1,
      anon_sym_LF,
    STATE(23), 1,
      aux_sym_paragraph_repeat1,
    ACTIONS(171), 12,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [368] = 3,
    ACTIONS(173), 1,
      ts_builtin_sym_end,
    ACTIONS(175), 1,
      anon_sym_LF,
    ACTIONS(177), 12,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [389] = 8,
    ACTIONS(179), 1,
      anon_sym_LF,
    ACTIONS(181), 1,
      anon_sym_STAR_STAR_STAR,
    ACTIONS(183), 1,
      anon_sym_STAR_STAR,
    ACTIONS(185), 1,
      anon_sym_STAR,
    ACTIONS(187), 1,
      anon_sym_BQUOTE,
    ACTIONS(189), 1,
      anon_sym_LBRACK,
    ACTIONS(191), 1,
      sym_text,
    STATE(37), 7,
      sym__inline,
      sym_bolditalic,
      sym_bold,
      sym_italic,
      sym_inline_code,
      sym_link,
      aux_sym_list_item_repeat1,
  [420] = 2,
    ACTIONS(193), 1,
      ts_builtin_sym_end,
    ACTIONS(195), 13,
      anon_sym_LF,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [439] = 3,
    ACTIONS(197), 1,
      ts_builtin_sym_end,
    ACTIONS(199), 1,
      anon_sym_LF,
    ACTIONS(201), 12,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [460] = 2,
    ACTIONS(203), 1,
      ts_builtin_sym_end,
    ACTIONS(205), 13,
      anon_sym_LF,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [479] = 2,
    ACTIONS(207), 1,
      ts_builtin_sym_end,
    ACTIONS(209), 13,
      anon_sym_LF,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [498] = 2,
    ACTIONS(211), 1,
      ts_builtin_sym_end,
    ACTIONS(213), 13,
      anon_sym_LF,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [517] = 2,
    ACTIONS(215), 1,
      ts_builtin_sym_end,
    ACTIONS(217), 13,
      anon_sym_LF,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [536] = 3,
    ACTIONS(219), 1,
      ts_builtin_sym_end,
    ACTIONS(221), 1,
      anon_sym_LF,
    ACTIONS(223), 12,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [557] = 3,
    ACTIONS(225), 1,
      ts_builtin_sym_end,
    ACTIONS(227), 1,
      anon_sym_LF,
    ACTIONS(229), 12,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [578] = 3,
    ACTIONS(231), 1,
      ts_builtin_sym_end,
    ACTIONS(233), 1,
      anon_sym_LF,
    ACTIONS(235), 12,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [599] = 3,
    ACTIONS(237), 1,
      ts_builtin_sym_end,
    ACTIONS(239), 1,
      anon_sym_LF,
    ACTIONS(241), 12,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [620] = 2,
    ACTIONS(243), 1,
      ts_builtin_sym_end,
    ACTIONS(245), 13,
      anon_sym_LF,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [639] = 8,
    ACTIONS(86), 1,
      anon_sym_LF,
    ACTIONS(247), 1,
      anon_sym_STAR_STAR_STAR,
    ACTIONS(250), 1,
      anon_sym_STAR_STAR,
    ACTIONS(253), 1,
      anon_sym_STAR,
    ACTIONS(256), 1,
      anon_sym_BQUOTE,
    ACTIONS(259), 1,
      anon_sym_LBRACK,
    ACTIONS(262), 1,
      sym_text,
    STATE(37), 7,
      sym__inline,
      sym_bolditalic,
      sym_bold,
      sym_italic,
      sym_inline_code,
      sym_link,
      aux_sym_list_item_repeat1,
  [670] = 7,
    ACTIONS(181), 1,
      anon_sym_STAR_STAR_STAR,
    ACTIONS(183), 1,
      anon_sym_STAR_STAR,
    ACTIONS(185), 1,
      anon_sym_STAR,
    ACTIONS(187), 1,
      anon_sym_BQUOTE,
    ACTIONS(189), 1,
      anon_sym_LBRACK,
    ACTIONS(265), 1,
      sym_text,
    STATE(25), 7,
      sym__inline,
      sym_bolditalic,
      sym_bold,
      sym_italic,
      sym_inline_code,
      sym_link,
      aux_sym_list_item_repeat1,
  [698] = 2,
    ACTIONS(267), 1,
      ts_builtin_sym_end,
    ACTIONS(269), 12,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [716] = 2,
    ACTIONS(271), 1,
      ts_builtin_sym_end,
    ACTIONS(273), 12,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [734] = 2,
    ACTIONS(275), 1,
      ts_builtin_sym_end,
    ACTIONS(277), 12,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [752] = 2,
    ACTIONS(279), 1,
      ts_builtin_sym_end,
    ACTIONS(281), 12,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [770] = 2,
    ACTIONS(283), 1,
      ts_builtin_sym_end,
    ACTIONS(285), 12,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [788] = 2,
    ACTIONS(287), 1,
      ts_builtin_sym_end,
    ACTIONS(289), 12,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [806] = 2,
    ACTIONS(291), 1,
      ts_builtin_sym_end,
    ACTIONS(293), 12,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [824] = 2,
    ACTIONS(295), 1,
      ts_builtin_sym_end,
    ACTIONS(297), 12,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [842] = 2,
    ACTIONS(299), 1,
      ts_builtin_sym_end,
    ACTIONS(301), 12,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [860] = 2,
    ACTIONS(303), 1,
      ts_builtin_sym_end,
    ACTIONS(305), 12,
      sym_heading_marker,
      sym_label_name,
      anon_sym_DASH,
      sym_ordered_marker,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      anon_sym_DOLLAR_DOLLAR,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [878] = 2,
    ACTIONS(307), 1,
      anon_sym_LPAREN,
    ACTIONS(155), 7,
      anon_sym_LF,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
      sym_text,
  [891] = 2,
    ACTIONS(211), 1,
      sym_text,
    ACTIONS(213), 6,
      anon_sym_LF,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
  [903] = 2,
    ACTIONS(193), 1,
      sym_text,
    ACTIONS(195), 6,
      anon_sym_LF,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
  [915] = 2,
    ACTIONS(203), 1,
      sym_text,
    ACTIONS(205), 6,
      anon_sym_LF,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
  [927] = 2,
    ACTIONS(207), 1,
      sym_text,
    ACTIONS(209), 6,
      anon_sym_LF,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
  [939] = 2,
    ACTIONS(243), 1,
      sym_text,
    ACTIONS(245), 6,
      anon_sym_LF,
      anon_sym_STAR_STAR_STAR,
      anon_sym_STAR_STAR,
      anon_sym_STAR,
      anon_sym_BQUOTE,
      anon_sym_LBRACK,
  [951] = 4,
    ACTIONS(309), 1,
      anon_sym_LF,
    ACTIONS(311), 1,
      aux_sym_code_line_token1,
    ACTIONS(313), 1,
      anon_sym_DOLLAR_DOLLAR,
    STATE(62), 2,
      sym_code_line,
      aux_sym_code_block_repeat1,
  [965] = 4,
    ACTIONS(315), 1,
      anon_sym_LF,
    ACTIONS(317), 1,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
    ACTIONS(319), 1,
      aux_sym_code_line_token1,
    STATE(61), 2,
      sym_code_line,
      aux_sym_code_block_repeat1,
  [979] = 4,
    ACTIONS(319), 1,
      aux_sym_code_line_token1,
    ACTIONS(321), 1,
      anon_sym_LF,
    ACTIONS(323), 1,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
    STATE(58), 2,
      sym_code_line,
      aux_sym_code_block_repeat1,
  [993] = 4,
    ACTIONS(315), 1,
      anon_sym_LF,
    ACTIONS(319), 1,
      aux_sym_code_line_token1,
    ACTIONS(325), 1,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
    STATE(61), 2,
      sym_code_line,
      aux_sym_code_block_repeat1,
  [1007] = 4,
    ACTIONS(311), 1,
      aux_sym_code_line_token1,
    ACTIONS(327), 1,
      anon_sym_LF,
    ACTIONS(329), 1,
      anon_sym_DOLLAR_DOLLAR,
    STATE(55), 2,
      sym_code_line,
      aux_sym_code_block_repeat1,
  [1021] = 4,
    ACTIONS(319), 1,
      aux_sym_code_line_token1,
    ACTIONS(331), 1,
      anon_sym_LF,
    ACTIONS(333), 1,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
    STATE(56), 2,
      sym_code_line,
      aux_sym_code_block_repeat1,
  [1035] = 4,
    ACTIONS(335), 1,
      anon_sym_LF,
    ACTIONS(338), 1,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
    ACTIONS(340), 1,
      aux_sym_code_line_token1,
    STATE(61), 2,
      sym_code_line,
      aux_sym_code_block_repeat1,
  [1049] = 4,
    ACTIONS(338), 1,
      anon_sym_DOLLAR_DOLLAR,
    ACTIONS(343), 1,
      anon_sym_LF,
    ACTIONS(346), 1,
      aux_sym_code_line_token1,
    STATE(62), 2,
      sym_code_line,
      aux_sym_code_block_repeat1,
  [1063] = 3,
    ACTIONS(349), 1,
      anon_sym_STAR_STAR_STAR,
    ACTIONS(351), 1,
      sym_text,
    STATE(66), 1,
      aux_sym_bolditalic_repeat1,
  [1073] = 3,
    ACTIONS(353), 1,
      anon_sym_STAR_STAR,
    ACTIONS(355), 1,
      sym_text,
    STATE(69), 1,
      aux_sym_bolditalic_repeat1,
  [1083] = 1,
    ACTIONS(357), 3,
      anon_sym_LF,
      anon_sym_BQUOTE_BQUOTE_BQUOTE,
      aux_sym_code_line_token1,
  [1089] = 3,
    ACTIONS(359), 1,
      anon_sym_STAR_STAR_STAR,
    ACTIONS(361), 1,
      sym_text,
    STATE(66), 1,
      aux_sym_bolditalic_repeat1,
  [1099] = 3,
    ACTIONS(364), 1,
      anon_sym_STAR,
    ACTIONS(366), 1,
      sym_text,
    STATE(71), 1,
      aux_sym_bolditalic_repeat1,
  [1109] = 3,
    ACTIONS(366), 1,
      sym_text,
    ACTIONS(368), 1,
      anon_sym_STAR,
    STATE(71), 1,
      aux_sym_bolditalic_repeat1,
  [1119] = 3,
    ACTIONS(359), 1,
      anon_sym_STAR_STAR,
    ACTIONS(370), 1,
      sym_text,
    STATE(69), 1,
      aux_sym_bolditalic_repeat1,
  [1129] = 1,
    ACTIONS(357), 3,
      anon_sym_LF,
      aux_sym_code_line_token1,
      anon_sym_DOLLAR_DOLLAR,
  [1135] = 3,
    ACTIONS(359), 1,
      anon_sym_STAR,
    ACTIONS(373), 1,
      sym_text,
    STATE(71), 1,
      aux_sym_bolditalic_repeat1,
  [1145] = 3,
    ACTIONS(351), 1,
      sym_text,
    ACTIONS(376), 1,
      anon_sym_STAR_STAR_STAR,
    STATE(66), 1,
      aux_sym_bolditalic_repeat1,
  [1155] = 3,
    ACTIONS(355), 1,
      sym_text,
    ACTIONS(378), 1,
      anon_sym_STAR_STAR,
    STATE(69), 1,
      aux_sym_bolditalic_repeat1,
  [1165] = 2,
    ACTIONS(380), 1,
      sym_text,
    STATE(68), 1,
      aux_sym_bolditalic_repeat1,
  [1172] = 2,
    ACTIONS(382), 1,
      aux_sym_code_line_token1,
    STATE(95), 1,
      sym_line_content,
  [1179] = 2,
    ACTIONS(384), 1,
      sym_text,
    STATE(64), 1,
      aux_sym_bolditalic_repeat1,
  [1186] = 2,
    ACTIONS(386), 1,
      anon_sym_LF,
    ACTIONS(388), 1,
      aux_sym_code_block_token1,
  [1193] = 2,
    ACTIONS(390), 1,
      sym_text,
    STATE(67), 1,
      aux_sym_bolditalic_repeat1,
  [1200] = 2,
    ACTIONS(392), 1,
      sym_text,
    STATE(63), 1,
      aux_sym_bolditalic_repeat1,
  [1207] = 2,
    ACTIONS(382), 1,
      aux_sym_code_line_token1,
    STATE(88), 1,
      sym_line_content,
  [1214] = 2,
    ACTIONS(394), 1,
      sym_text,
    STATE(73), 1,
      aux_sym_bolditalic_repeat1,
  [1221] = 2,
    ACTIONS(396), 1,
      sym_text,
    STATE(72), 1,
      aux_sym_bolditalic_repeat1,
  [1228] = 1,
    ACTIONS(398), 1,
      anon_sym_SPACE,
  [1232] = 1,
    ACTIONS(400), 1,
      anon_sym_RPAREN,
  [1236] = 1,
    ACTIONS(402), 1,
      aux_sym_inline_code_token1,
  [1240] = 1,
    ACTIONS(404), 1,
      anon_sym_LF,
  [1244] = 1,
    ACTIONS(406), 1,
      anon_sym_LF,
  [1248] = 1,
    ACTIONS(408), 1,
      anon_sym_LF,
  [1252] = 1,
    ACTIONS(410), 1,
      aux_sym_link_token1,
  [1256] = 1,
    ACTIONS(412), 1,
      ts_builtin_sym_end,
  [1260] = 1,
    ACTIONS(414), 1,
      anon_sym_LF,
  [1264] = 1,
    ACTIONS(416), 1,
      anon_sym_COLON,
  [1268] = 1,
    ACTIONS(418), 1,
      anon_sym_LF,
  [1272] = 1,
    ACTIONS(420), 1,
      anon_sym_BQUOTE,
  [1276] = 1,
    ACTIONS(422), 1,
      anon_sym_LF,
  [1280] = 1,
    ACTIONS(424), 1,
      aux_sym_link_token2,
  [1284] = 1,
    ACTIONS(426), 1,
      anon_sym_BQUOTE,
  [1288] = 1,
    ACTIONS(428), 1,
      anon_sym_RBRACK,
  [1292] = 1,
    ACTIONS(430), 1,
      anon_sym_RPAREN,
  [1296] = 1,
    ACTIONS(432), 1,
      anon_sym_LF,
  [1300] = 1,
    ACTIONS(434), 1,
      anon_sym_RBRACK,
  [1304] = 1,
    ACTIONS(436), 1,
      sym_tag_name,
  [1308] = 1,
    ACTIONS(438), 1,
      aux_sym_inline_code_token1,
  [1312] = 1,
    ACTIONS(440), 1,
      aux_sym_link_token1,
  [1316] = 1,
    ACTIONS(442), 1,
      aux_sym_link_token2,
};

static const uint32_t ts_small_parse_table_map[] = {
  [SMALL_STATE(10)] = 0,
  [SMALL_STATE(11)] = 45,
  [SMALL_STATE(12)] = 85,
  [SMALL_STATE(13)] = 112,
  [SMALL_STATE(14)] = 138,
  [SMALL_STATE(15)] = 164,
  [SMALL_STATE(16)] = 185,
  [SMALL_STATE(17)] = 210,
  [SMALL_STATE(18)] = 232,
  [SMALL_STATE(19)] = 254,
  [SMALL_STATE(20)] = 274,
  [SMALL_STATE(21)] = 298,
  [SMALL_STATE(22)] = 320,
  [SMALL_STATE(23)] = 344,
  [SMALL_STATE(24)] = 368,
  [SMALL_STATE(25)] = 389,
  [SMALL_STATE(26)] = 420,
  [SMALL_STATE(27)] = 439,
  [SMALL_STATE(28)] = 460,
  [SMALL_STATE(29)] = 479,
  [SMALL_STATE(30)] = 498,
  [SMALL_STATE(31)] = 517,
  [SMALL_STATE(32)] = 536,
  [SMALL_STATE(33)] = 557,
  [SMALL_STATE(34)] = 578,
  [SMALL_STATE(35)] = 599,
  [SMALL_STATE(36)] = 620,
  [SMALL_STATE(37)] = 639,
  [SMALL_STATE(38)] = 670,
  [SMALL_STATE(39)] = 698,
  [SMALL_STATE(40)] = 716,
  [SMALL_STATE(41)] = 734,
  [SMALL_STATE(42)] = 752,
  [SMALL_STATE(43)] = 770,
  [SMALL_STATE(44)] = 788,
  [SMALL_STATE(45)] = 806,
  [SMALL_STATE(46)] = 824,
  [SMALL_STATE(47)] = 842,
  [SMALL_STATE(48)] = 860,
  [SMALL_STATE(49)] = 878,
  [SMALL_STATE(50)] = 891,
  [SMALL_STATE(51)] = 903,
  [SMALL_STATE(52)] = 915,
  [SMALL_STATE(53)] = 927,
  [SMALL_STATE(54)] = 939,
  [SMALL_STATE(55)] = 951,
  [SMALL_STATE(56)] = 965,
  [SMALL_STATE(57)] = 979,
  [SMALL_STATE(58)] = 993,
  [SMALL_STATE(59)] = 1007,
  [SMALL_STATE(60)] = 1021,
  [SMALL_STATE(61)] = 1035,
  [SMALL_STATE(62)] = 1049,
  [SMALL_STATE(63)] = 1063,
  [SMALL_STATE(64)] = 1073,
  [SMALL_STATE(65)] = 1083,
  [SMALL_STATE(66)] = 1089,
  [SMALL_STATE(67)] = 1099,
  [SMALL_STATE(68)] = 1109,
  [SMALL_STATE(69)] = 1119,
  [SMALL_STATE(70)] = 1129,
  [SMALL_STATE(71)] = 1135,
  [SMALL_STATE(72)] = 1145,
  [SMALL_STATE(73)] = 1155,
  [SMALL_STATE(74)] = 1165,
  [SMALL_STATE(75)] = 1172,
  [SMALL_STATE(76)] = 1179,
  [SMALL_STATE(77)] = 1186,
  [SMALL_STATE(78)] = 1193,
  [SMALL_STATE(79)] = 1200,
  [SMALL_STATE(80)] = 1207,
  [SMALL_STATE(81)] = 1214,
  [SMALL_STATE(82)] = 1221,
  [SMALL_STATE(83)] = 1228,
  [SMALL_STATE(84)] = 1232,
  [SMALL_STATE(85)] = 1236,
  [SMALL_STATE(86)] = 1240,
  [SMALL_STATE(87)] = 1244,
  [SMALL_STATE(88)] = 1248,
  [SMALL_STATE(89)] = 1252,
  [SMALL_STATE(90)] = 1256,
  [SMALL_STATE(91)] = 1260,
  [SMALL_STATE(92)] = 1264,
  [SMALL_STATE(93)] = 1268,
  [SMALL_STATE(94)] = 1272,
  [SMALL_STATE(95)] = 1276,
  [SMALL_STATE(96)] = 1280,
  [SMALL_STATE(97)] = 1284,
  [SMALL_STATE(98)] = 1288,
  [SMALL_STATE(99)] = 1292,
  [SMALL_STATE(100)] = 1296,
  [SMALL_STATE(101)] = 1300,
  [SMALL_STATE(102)] = 1304,
  [SMALL_STATE(103)] = 1308,
  [SMALL_STATE(104)] = 1312,
  [SMALL_STATE(105)] = 1316,
};

static const TSParseActionEntry ts_parse_actions[] = {
  [0] = {.entry = {.count = 0, .reusable = false}},
  [1] = {.entry = {.count = 1, .reusable = false}}, RECOVER(),
  [3] = {.entry = {.count = 1, .reusable = true}}, SHIFT(80),
  [5] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_document, 1, 0, 0),
  [7] = {.entry = {.count = 1, .reusable = false}}, SHIFT(80),
  [9] = {.entry = {.count = 1, .reusable = false}}, SHIFT(31),
  [11] = {.entry = {.count = 1, .reusable = false}}, SHIFT(102),
  [13] = {.entry = {.count = 1, .reusable = false}}, SHIFT(75),
  [15] = {.entry = {.count = 1, .reusable = false}}, SHIFT(92),
  [17] = {.entry = {.count = 1, .reusable = false}}, SHIFT(83),
  [19] = {.entry = {.count = 1, .reusable = false}}, SHIFT(77),
  [21] = {.entry = {.count = 1, .reusable = false}}, SHIFT(86),
  [23] = {.entry = {.count = 1, .reusable = false}}, SHIFT(79),
  [25] = {.entry = {.count = 1, .reusable = false}}, SHIFT(76),
  [27] = {.entry = {.count = 1, .reusable = false}}, SHIFT(78),
  [29] = {.entry = {.count = 1, .reusable = false}}, SHIFT(85),
  [31] = {.entry = {.count = 1, .reusable = false}}, SHIFT(89),
  [33] = {.entry = {.count = 1, .reusable = false}}, SHIFT(10),
  [35] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_document, 2, 0, 0),
  [37] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_document, 3, 0, 0),
  [39] = {.entry = {.count = 1, .reusable = true}}, REDUCE(aux_sym_document_repeat3, 2, 0, 0),
  [41] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_document_repeat3, 2, 0, 0), SHIFT_REPEAT(75),
  [44] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_document_repeat3, 2, 0, 0), SHIFT_REPEAT(92),
  [47] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_document_repeat3, 2, 0, 0), SHIFT_REPEAT(83),
  [50] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_document_repeat3, 2, 0, 0), SHIFT_REPEAT(77),
  [53] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_document_repeat3, 2, 0, 0), SHIFT_REPEAT(86),
  [56] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_document_repeat3, 2, 0, 0), SHIFT_REPEAT(79),
  [59] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_document_repeat3, 2, 0, 0), SHIFT_REPEAT(76),
  [62] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_document_repeat3, 2, 0, 0), SHIFT_REPEAT(78),
  [65] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_document_repeat3, 2, 0, 0), SHIFT_REPEAT(85),
  [68] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_document_repeat3, 2, 0, 0), SHIFT_REPEAT(89),
  [71] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_document_repeat3, 2, 0, 0), SHIFT_REPEAT(10),
  [74] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_document, 4, 0, 0),
  [76] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_paragraph, 1, 0, 0),
  [78] = {.entry = {.count = 1, .reusable = false}}, SHIFT(20),
  [80] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_paragraph, 1, 0, 0),
  [82] = {.entry = {.count = 1, .reusable = false}}, SHIFT(11),
  [84] = {.entry = {.count = 1, .reusable = true}}, REDUCE(aux_sym_list_item_repeat1, 2, 0, 0),
  [86] = {.entry = {.count = 1, .reusable = false}}, REDUCE(aux_sym_list_item_repeat1, 2, 0, 0),
  [88] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_list_item_repeat1, 2, 0, 0), SHIFT_REPEAT(79),
  [91] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_list_item_repeat1, 2, 0, 0), SHIFT_REPEAT(76),
  [94] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_list_item_repeat1, 2, 0, 0), SHIFT_REPEAT(78),
  [97] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_list_item_repeat1, 2, 0, 0), SHIFT_REPEAT(85),
  [100] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_list_item_repeat1, 2, 0, 0), SHIFT_REPEAT(89),
  [103] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_list_item_repeat1, 2, 0, 0), SHIFT_REPEAT(11),
  [106] = {.entry = {.count = 1, .reusable = true}}, REDUCE(aux_sym_document_repeat1, 2, 0, 0),
  [108] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_document_repeat1, 2, 0, 0), SHIFT_REPEAT(80),
  [111] = {.entry = {.count = 1, .reusable = false}}, REDUCE(aux_sym_document_repeat1, 2, 0, 0),
  [113] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_tags, 1, 0, 0),
  [115] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_tags, 1, 0, 0),
  [117] = {.entry = {.count = 1, .reusable = true}}, REDUCE(aux_sym_tags_repeat1, 2, 0, 0),
  [119] = {.entry = {.count = 1, .reusable = false}}, REDUCE(aux_sym_tags_repeat1, 2, 0, 0),
  [121] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_tags_repeat1, 2, 0, 0), SHIFT_REPEAT(102),
  [124] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_article_header, 3, 0, 1),
  [126] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_article_header, 3, 0, 1),
  [128] = {.entry = {.count = 1, .reusable = true}}, REDUCE(aux_sym_document_repeat2, 2, 0, 0),
  [130] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_document_repeat2, 2, 0, 0), SHIFT_REPEAT(31),
  [133] = {.entry = {.count = 1, .reusable = false}}, REDUCE(aux_sym_document_repeat2, 2, 0, 0),
  [135] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_list, 1, 0, 0),
  [137] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_list, 1, 0, 0),
  [139] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_list, 2, 0, 0),
  [141] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_list, 2, 0, 0),
  [143] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_tag_line, 3, 0, 1),
  [145] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_tag_line, 3, 0, 1),
  [147] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_paragraph, 2, 0, 0),
  [149] = {.entry = {.count = 1, .reusable = false}}, SHIFT(23),
  [151] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_paragraph, 2, 0, 0),
  [153] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_link, 3, 0, 4),
  [155] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_link, 3, 0, 4),
  [157] = {.entry = {.count = 1, .reusable = false}}, SHIFT(96),
  [159] = {.entry = {.count = 1, .reusable = true}}, REDUCE(aux_sym_list_repeat1, 2, 0, 0),
  [161] = {.entry = {.count = 1, .reusable = false}}, REDUCE(aux_sym_list_repeat1, 2, 0, 0),
  [163] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_list_repeat1, 2, 0, 0), SHIFT_REPEAT(83),
  [166] = {.entry = {.count = 1, .reusable = true}}, REDUCE(aux_sym_paragraph_repeat1, 2, 0, 0),
  [168] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_paragraph_repeat1, 2, 0, 0), SHIFT_REPEAT(23),
  [171] = {.entry = {.count = 1, .reusable = false}}, REDUCE(aux_sym_paragraph_repeat1, 2, 0, 0),
  [173] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_code_block, 3, 0, 0),
  [175] = {.entry = {.count = 1, .reusable = false}}, SHIFT(44),
  [177] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_code_block, 3, 0, 0),
  [179] = {.entry = {.count = 1, .reusable = false}}, SHIFT(42),
  [181] = {.entry = {.count = 1, .reusable = false}}, SHIFT(82),
  [183] = {.entry = {.count = 1, .reusable = false}}, SHIFT(81),
  [185] = {.entry = {.count = 1, .reusable = false}}, SHIFT(74),
  [187] = {.entry = {.count = 1, .reusable = false}}, SHIFT(103),
  [189] = {.entry = {.count = 1, .reusable = false}}, SHIFT(104),
  [191] = {.entry = {.count = 1, .reusable = true}}, SHIFT(37),
  [193] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_bold, 3, 0, 0),
  [195] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_bold, 3, 0, 0),
  [197] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_latex_block, 3, 0, 0),
  [199] = {.entry = {.count = 1, .reusable = false}}, SHIFT(45),
  [201] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_latex_block, 3, 0, 0),
  [203] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_bolditalic, 3, 0, 0),
  [205] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_bolditalic, 3, 0, 0),
  [207] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_italic, 3, 0, 0),
  [209] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_italic, 3, 0, 0),
  [211] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_inline_code, 3, 0, 0),
  [213] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_inline_code, 3, 0, 0),
  [215] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_blank_line, 1, 0, 0),
  [217] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_blank_line, 1, 0, 0),
  [219] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_latex_block, 4, 0, 6),
  [221] = {.entry = {.count = 1, .reusable = false}}, SHIFT(47),
  [223] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_latex_block, 4, 0, 6),
  [225] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_code_block, 4, 0, 6),
  [227] = {.entry = {.count = 1, .reusable = false}}, SHIFT(48),
  [229] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_code_block, 4, 0, 6),
  [231] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_code_block, 4, 0, 7),
  [233] = {.entry = {.count = 1, .reusable = false}}, SHIFT(43),
  [235] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_code_block, 4, 0, 7),
  [237] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_code_block, 5, 0, 8),
  [239] = {.entry = {.count = 1, .reusable = false}}, SHIFT(46),
  [241] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_code_block, 5, 0, 8),
  [243] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_link, 6, 0, 9),
  [245] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_link, 6, 0, 9),
  [247] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_list_item_repeat1, 2, 0, 0), SHIFT_REPEAT(82),
  [250] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_list_item_repeat1, 2, 0, 0), SHIFT_REPEAT(81),
  [253] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_list_item_repeat1, 2, 0, 0), SHIFT_REPEAT(74),
  [256] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_list_item_repeat1, 2, 0, 0), SHIFT_REPEAT(103),
  [259] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_list_item_repeat1, 2, 0, 0), SHIFT_REPEAT(104),
  [262] = {.entry = {.count = 2, .reusable = true}}, REDUCE(aux_sym_list_item_repeat1, 2, 0, 0), SHIFT_REPEAT(37),
  [265] = {.entry = {.count = 1, .reusable = true}}, SHIFT(25),
  [267] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_label, 3, 0, 3),
  [269] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_label, 3, 0, 3),
  [271] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_heading, 3, 0, 2),
  [273] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_heading, 3, 0, 2),
  [275] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_block, 1, 0, 0),
  [277] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_block, 1, 0, 0),
  [279] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_list_item, 4, 0, 5),
  [281] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_list_item, 4, 0, 5),
  [283] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_code_block, 5, 0, 7),
  [285] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_code_block, 5, 0, 7),
  [287] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_code_block, 4, 0, 0),
  [289] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_code_block, 4, 0, 0),
  [291] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_latex_block, 4, 0, 0),
  [293] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_latex_block, 4, 0, 0),
  [295] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_code_block, 6, 0, 8),
  [297] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_code_block, 6, 0, 8),
  [299] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_latex_block, 5, 0, 6),
  [301] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_latex_block, 5, 0, 6),
  [303] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_code_block, 5, 0, 6),
  [305] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_code_block, 5, 0, 6),
  [307] = {.entry = {.count = 1, .reusable = false}}, SHIFT(105),
  [309] = {.entry = {.count = 1, .reusable = false}}, SHIFT(62),
  [311] = {.entry = {.count = 1, .reusable = false}}, SHIFT(70),
  [313] = {.entry = {.count = 1, .reusable = false}}, SHIFT(32),
  [315] = {.entry = {.count = 1, .reusable = false}}, SHIFT(61),
  [317] = {.entry = {.count = 1, .reusable = false}}, SHIFT(35),
  [319] = {.entry = {.count = 1, .reusable = false}}, SHIFT(65),
  [321] = {.entry = {.count = 1, .reusable = false}}, SHIFT(58),
  [323] = {.entry = {.count = 1, .reusable = false}}, SHIFT(24),
  [325] = {.entry = {.count = 1, .reusable = false}}, SHIFT(33),
  [327] = {.entry = {.count = 1, .reusable = false}}, SHIFT(55),
  [329] = {.entry = {.count = 1, .reusable = false}}, SHIFT(27),
  [331] = {.entry = {.count = 1, .reusable = false}}, SHIFT(56),
  [333] = {.entry = {.count = 1, .reusable = false}}, SHIFT(34),
  [335] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_code_block_repeat1, 2, 0, 0), SHIFT_REPEAT(61),
  [338] = {.entry = {.count = 1, .reusable = false}}, REDUCE(aux_sym_code_block_repeat1, 2, 0, 0),
  [340] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_code_block_repeat1, 2, 0, 0), SHIFT_REPEAT(65),
  [343] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_code_block_repeat1, 2, 0, 0), SHIFT_REPEAT(62),
  [346] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_code_block_repeat1, 2, 0, 0), SHIFT_REPEAT(70),
  [349] = {.entry = {.count = 1, .reusable = false}}, SHIFT(28),
  [351] = {.entry = {.count = 1, .reusable = true}}, SHIFT(66),
  [353] = {.entry = {.count = 1, .reusable = false}}, SHIFT(26),
  [355] = {.entry = {.count = 1, .reusable = true}}, SHIFT(69),
  [357] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_code_line, 1, 0, 0),
  [359] = {.entry = {.count = 1, .reusable = false}}, REDUCE(aux_sym_bolditalic_repeat1, 2, 0, 0),
  [361] = {.entry = {.count = 2, .reusable = true}}, REDUCE(aux_sym_bolditalic_repeat1, 2, 0, 0), SHIFT_REPEAT(66),
  [364] = {.entry = {.count = 1, .reusable = false}}, SHIFT(29),
  [366] = {.entry = {.count = 1, .reusable = true}}, SHIFT(71),
  [368] = {.entry = {.count = 1, .reusable = false}}, SHIFT(53),
  [370] = {.entry = {.count = 2, .reusable = true}}, REDUCE(aux_sym_bolditalic_repeat1, 2, 0, 0), SHIFT_REPEAT(69),
  [373] = {.entry = {.count = 2, .reusable = true}}, REDUCE(aux_sym_bolditalic_repeat1, 2, 0, 0), SHIFT_REPEAT(71),
  [376] = {.entry = {.count = 1, .reusable = false}}, SHIFT(52),
  [378] = {.entry = {.count = 1, .reusable = false}}, SHIFT(51),
  [380] = {.entry = {.count = 1, .reusable = true}}, SHIFT(68),
  [382] = {.entry = {.count = 1, .reusable = true}}, SHIFT(87),
  [384] = {.entry = {.count = 1, .reusable = true}}, SHIFT(64),
  [386] = {.entry = {.count = 1, .reusable = true}}, SHIFT(57),
  [388] = {.entry = {.count = 1, .reusable = true}}, SHIFT(91),
  [390] = {.entry = {.count = 1, .reusable = true}}, SHIFT(67),
  [392] = {.entry = {.count = 1, .reusable = true}}, SHIFT(63),
  [394] = {.entry = {.count = 1, .reusable = true}}, SHIFT(73),
  [396] = {.entry = {.count = 1, .reusable = true}}, SHIFT(72),
  [398] = {.entry = {.count = 1, .reusable = true}}, SHIFT(38),
  [400] = {.entry = {.count = 1, .reusable = true}}, SHIFT(36),
  [402] = {.entry = {.count = 1, .reusable = true}}, SHIFT(94),
  [404] = {.entry = {.count = 1, .reusable = true}}, SHIFT(59),
  [406] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_line_content, 1, 0, 0),
  [408] = {.entry = {.count = 1, .reusable = true}}, SHIFT(15),
  [410] = {.entry = {.count = 1, .reusable = true}}, SHIFT(101),
  [412] = {.entry = {.count = 1, .reusable = true}},  ACCEPT_INPUT(),
  [414] = {.entry = {.count = 1, .reusable = true}}, SHIFT(60),
  [416] = {.entry = {.count = 1, .reusable = true}}, SHIFT(100),
  [418] = {.entry = {.count = 1, .reusable = true}}, SHIFT(19),
  [420] = {.entry = {.count = 1, .reusable = true}}, SHIFT(30),
  [422] = {.entry = {.count = 1, .reusable = true}}, SHIFT(40),
  [424] = {.entry = {.count = 1, .reusable = true}}, SHIFT(84),
  [426] = {.entry = {.count = 1, .reusable = true}}, SHIFT(50),
  [428] = {.entry = {.count = 1, .reusable = true}}, SHIFT(49),
  [430] = {.entry = {.count = 1, .reusable = true}}, SHIFT(54),
  [432] = {.entry = {.count = 1, .reusable = true}}, SHIFT(39),
  [434] = {.entry = {.count = 1, .reusable = true}}, SHIFT(21),
  [436] = {.entry = {.count = 1, .reusable = true}}, SHIFT(93),
  [438] = {.entry = {.count = 1, .reusable = true}}, SHIFT(97),
  [440] = {.entry = {.count = 1, .reusable = true}}, SHIFT(98),
  [442] = {.entry = {.count = 1, .reusable = true}}, SHIFT(99),
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
