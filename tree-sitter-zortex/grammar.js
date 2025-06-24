// Bare‑bones Tree‑sitter grammar for the **zortex** markup language.
// Patch #3 — minimise spurious `label` matches in running text and favour `paragraph`.
//   • `block` choice order changed: paragraph precedes label.
//   • `label` now demands *no* trailing content other than a newline (end-of-line anchor).
//   • Added `token(…)` usage for label’s colon‑newline combo to reduce back‑tracking.
//   • Widened `text` again to swallow unmatched punctuation (prevent partial parses).

module.exports = grammar({
  name: "zortex",

  /* -------------------------------- Extras -------------------------------- */
  extras: ($) => [/[ \t\f\r]+/],

  /* --------------------------- Precedence helpers ------------------------- */
  precedences: ($) => [["list", $.list_item]],

  /* ------------------------------- Conflicts ------------------------------ */
  conflicts: ($) => [[$.list, $.paragraph]],

  /* ------------------------------ Top‑level ------------------------------- */
  rules: {
    document: ($) =>
      seq(
        repeat1($.article_header),
        optional($.tags),
        repeat($.blank_line),
        repeat($.block),
      ),

    /* ------------------------- Structural lines --------------------------- */
    article_header: ($) => seq("@@", field("name", $.line_content), "\n"),

    tags: ($) => repeat1($.tag_line),
    tag_line: ($) => seq("@", field("name", $.tag_name), "\n"),
    tag_name: ($) => /[^\s\n]+/,

    /* ---------------------------- Body blocks ----------------------------- */
    block: ($) =>
      choice(
        $.heading,
        $.list,
        $.code_block,
        $.latex_block,
        $.paragraph, // ← now *before* label to win ambiguous lines
        $.label,
      ),

    /* Headings */
    heading: ($) =>
      seq(
        field("marker", $.heading_marker),
        field("text", $.line_content),
        "\n",
      ),
    heading_marker: ($) => token(/#{1,6}/),

    /* Labels (must be a standalone line ending right after the colon) */
    label: ($) => seq(field("name", $.label_name), token(":"), "\n"),
    label_name: ($) => /[A-Za-z0-9 ][A-Za-z0-9 ]*/,

    /* Lists */
    list: ($) => prec.left(seq($.list_item, repeat($.list_item))),

    list_item: ($) =>
      seq(
        field("marker", choice("-", $.ordered_marker)),
        " ",
        repeat1($._inline),
        "\n",
      ),
    ordered_marker: ($) => /\d+\./,

    /* Fenced code */
    code_block: ($) =>
      seq(
        "```",
        optional(field("language", /[A-Za-z0-9_-]+/)),
        "\n",
        field("content", repeat(choice($.code_line, "\n"))),
        "```",
        optional("\n"),
      ),
    code_line: ($) => /[^\n]+/,

    /* Fenced LaTeX */
    latex_block: ($) =>
      seq(
        "$$",
        "\n",
        field("content", repeat(choice($.code_line, "\n"))),
        "$$",
        optional("\n"),
      ),

    /* Paragraph */
    paragraph: ($) => prec.right(seq(repeat1($._inline), repeat("\n"))),

    /* ------------------------------ Inline ------------------------------- */
    _inline: ($) =>
      choice($.bolditalic, $.bold, $.italic, $.inline_code, $.link, $.text),

    bolditalic: ($) => seq("***", repeat1($.text), "***"),
    bold: ($) => seq("**", repeat1($.text), "**"),
    italic: ($) => seq("*", repeat1($.text), "*"),
    inline_code: ($) => seq("`", /[^`]+/, "`"),

    link: ($) =>
      seq(
        "[",
        field("text", /[^\]]+/),
        "]",
        optional(seq("(", field("url", /[^)]+/), ")")),
      ),

    /* ---------------------------- Terminals ----------------------------- */
    text: ($) => /[^*`\n\[\]]+/, // include ':' so it stays inside paragraph
    line_content: ($) => /[^\n]+/,
    blank_line: ($) => "\n",
  },
});

/* NEXT STEPS --------------------------------------------------------------
 * – Add externals: $ => [ $.indent, $.dedent ] once indentation nesting is needed.
 */
