module.exports = grammar({
  name: "zortex",
  /* -------------------------------- Extras -------------------------------- */
  extras: ($) => [/[ \t\f\r]+/],
  /* --------------------------- Precedence helpers ------------------------- */
  precedences: ($) => [
    ["special_line", "paragraph"],
    ["list", "paragraph"],
  ],
  /* ------------------------------- Conflicts ------------------------------ */
  conflicts: ($) => [[$.list, $.paragraph]],
  /* ------------------------------ Top‑level ------------------------------- */
  rules: {
    document: ($) =>
      seq(repeat1($.article_header), repeat($.tag_line), repeat($.block)),

    /* ------------------------- Structural lines --------------------------- */
    article_header: ($) => seq("@@", field("name", $.line_content), "\n"),

    tag_line: ($) => seq("@", field("name", $.line_content), "\n"),

    /* ---------------------------- Body blocks ----------------------------- */
    block: ($) =>
      choice(
        $.blank_line,
        $.list,
        $.code_block,
        $.latex_block,
        $.heading,
        $.label,
        $.paragraph,
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
    list: ($) => prec.left("list", seq($.list_item, repeat($.list_item))),
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
      ),
    code_line: ($) => /[^\n]+/,

    /* Fenced LaTeX */
    latex_block: ($) =>
      seq(
        "$$",
        "\n",
        field("content", repeat(choice($.code_line, "\n"))),
        "$$",
      ),

    /* Paragraph - constrained to not start with special characters */
    paragraph: ($) =>
      seq($.paragraph_start, repeat(seq($.paragraph_line, "\n")), "\n"),

    // First line of paragraph - explicit token that excludes special starts
    paragraph_start: ($) => token(prec(-1, /[^@#`$\-0-9\n][^\n]*/)),

    // Additional paragraph lines
    paragraph_line: ($) => token(prec(-1, /[^@#`$\-0-9\n][^\n]*/)),

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
    text: ($) => /[^*`\n\[\]]+/,
    line_content: ($) => /[^\n]+/,
    blank_line: ($) => "\n",
  },
});
/* NEXT STEPS --------------------------------------------------------------
 * – Add externals: $ => [ $.indent, $.dedent ] once indentation nesting is needed.
 */
