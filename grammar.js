// grammar.js
module.exports = grammar({
  name: "custom_markdown",

  // Whitespace and comments that can appear anywhere
  extras: ($) => [
    /[ \t]+/, // Allow spaces and tabs
    // $.line_comment, // Example if line comments were supported (e.g., // comment)
  ],

  // Rules that might conflict and need explicit resolution
  conflicts: ($) => [
    // Potentially, inline content vs. start of new blocks if not careful with line starts.
    // Precedence rules below should handle most common cases for formatting.
    [$._text_inline, $.link], // To ensure link parsing is preferred over plain text if ambiguous.
  ],

  // Precedence for ambiguous parsing, e.g., *** vs ** and *
  precedences: ($) => [
    [$.bold_italic, $.bold, $.italic], // *** wins over **, which wins over *
    [$.code_block, $.latex_block, $.list, $.heading, $.label, $.paragraph], // Block-level precedence
  ],

  rules: {
    // Root node: document
    document: ($) =>
      seq(
        optional($.article_headers),
        optional($.tags),
        optional($._blank_lines), // Separator blank lines
        optional($.body),
      ),

    // 1. Article Headers
    article_headers: ($) => repeat1($.article_header),
    article_header: ($) => seq("@@", field("name", $.article_name), $._newline),
    article_name: ($) => token(prec(1, /[^\n]+/)), // Any char except newline

    // 2. Tags
    tags: ($) => repeat1($.tag_line), // Schema: tag_line* (optional, zero or more)
    // If it must appear after headers, structure is fine.
    // If tags can be empty, use `optional(repeat1($.tag_line))`
    tag_line: ($) => seq("@", field("name", $.tag_name), $._newline),
    tag_name: ($) => token(/[^\s@\n]+/), // Any non-whitespace, non-@, non-newline char

    // 3. Blank Lines (structural separator)
    _blank_lines: ($) => repeat1($._blank_line),
    _blank_line: ($) => alias($._newline, $.blank_line_separator),

    // 4. Body Content
    body: ($) => repeat1($._block),

    _block: ($) =>
      choice(
        $.heading,
        $.label,
        $.list,
        $.code_block,
        $.latex_block,
        $.paragraph,
        $._blank_line, // Allow blank lines between blocks in the body
      ),

    // 5. Headings
    heading: ($) =>
      seq(
        field("marker", $.heading_marker),
        " ", // Required space after marker
        field("text", $.heading_text),
        choice($._newline, $._eof), // Heading can be the last line
      ),
    heading_marker: ($) => token(/#+/),
    heading_text: ($) =>
      repeat1(
        choice(
          $.inline_code, // Allow inline code in headings
          $.latex_inline, // Allow inline LaTeX in headings
          token(prec(1, /[^#`$\n\\]+/)), // Text, not starting other inline elements for heading
          $._escaped_char_generic, // Allow escaped characters
        ),
      ),

    // 6. Labels
    label: ($) => seq(field("name", $.label_name), ":", $._newline),
    label_name: ($) => token(/[A-Za-z0-9][A-Za-z0-9 ]*/), // Must start with alphanumeric, can contain spaces

    // 7. Paragraphs
    // A paragraph is a sequence of inline content.
    // It's terminated by a blank line, the start of another block, or EOF.
    paragraph: ($) =>
      prec.dynamic(
        -1,
        seq(repeat1($._inline_item), choice($._newline, $._eof)),
      ),

    // Unified inline item definition
    _inline_item: ($) =>
      choice(
        $.link,
        $.formatted_text,
        $.inline_code,
        $.latex_inline,
        $._text_inline, // General text
      ),

    // General text token for inline content
    _text_inline: ($) => token(prec(-1, /([^\[*`$\n\\]|\\.)+/)), // Text not starting other inline constructs, allows escaped chars.

    // Escaped character (generic)
    _escaped_char_generic: ($) => token.immediate(/\\./), // Escape any character

    // 8. Links
    link: ($) =>
      choice(
        // Markdown style: [text](url)
        seq(
          "[",
          field("text", repeat1($._link_text_content)),
          "]",
          "(",
          field("url", repeat($._url_content)), // URL can be empty
          ")",
        ),
        // Article/Subpath style: [Article/#Heading], [Article/:Label], [/LocalHeading], [Article]
        seq(
          "[",
          field("path", repeat1($._link_text_content)), // 'text' here is the article path/target
          "]",
        ),
      ),
    _link_text_content: ($) =>
      choice(
        token.immediate(/[^\]\\]+/), // Unescaped characters within link text
        $._escaped_char_generic, // Escaped characters like \] or \\
      ),
    _url_content: ($) =>
      choice(
        token.immediate(/[^)\s\\]+/), // Unescaped characters within URL (no spaces, no closing paren)
        $._escaped_char_generic, // Escaped characters like \) or \\
      ),

    // 9. Lists
    list: ($) => repeat1(choice($.bullet_list_item, $.numbered_list_item)),

    bullet_list_item: ($) =>
      seq(
        choice("-", "*", "+"), // Common bullet markers
        " ",
        repeat1($._inline_item),
        choice($._newline, $._eof),
        // Note: Nested lists typically require indentation handling, often via an external scanner.
        // This basic version handles flat lists.
      ),
    numbered_list_item: ($) =>
      seq(/\d+\./, " ", repeat1($._inline_item), choice($._newline, $._eof)),

    // 10. Inline Code & Code Blocks
    inline_code: ($) =>
      seq(
        "`",
        field("content", token.immediate(/[^`\n]+/)), // Content cannot contain backticks or newlines
        "`",
      ),
    code_block: ($) =>
      seq(
        "```",
        optional(field("language", $.language_name)),
        $._newline,
        // Content of a code block. For robustness, an external scanner is best.
        // This version captures lines until the closing fence.
        field(
          "content",
          optional(repeat(choice($._code_block_line, $._newline_in_block))),
        ),
        "```",
        choice($._newline, $._eof),
      ),
    language_name: ($) => token(/[a-zA-Z0-9]+/),
    _code_block_line: ($) => token.immediate(prec(1, /[^\n]+/)), // A line of content that is not the fence itself.
    // This simplified rule means a line identical to '```' would end the block.
    _newline_in_block: ($) => $._newline, // Explicit newline capture within blocks

    // 11. LaTeX / Math Blocks
    latex_inline: ($) =>
      seq(
        "$",
        field("content", token.immediate(/[^$\n]+/)), // Content cannot contain $ or newlines
        "$",
      ),
    latex_block: ($) =>
      seq(
        "$$",
        $._newline,
        // Content of a LaTeX block. Similar to code blocks, external scanner is preferred for complex cases.
        field(
          "content",
          optional(repeat(choice($._latex_block_line, $._newline_in_block))),
        ),
        "$$",
        choice($._newline, $._eof),
      ),
    _latex_block_line: ($) => token.immediate(prec(1, /[^\n]+/)), // A line of content. Line '$$' would end it.

    // 12. Formatting (Bold, Italic, Bold-Italic)
    // Precedence: bold_italic > bold > italic (handled by `precedences` array)
    formatted_text: ($) => choice($.bold_italic, $.bold, $.italic),

    // For bold, italic, bold_italic, the content is a sequence of _inline_item.
    // The parser, guided by precedence and tokenization of delimiters, handles nesting.
    // E.g., in '**hello *world***', 'hello ' is text, '*world*' is an italic node.
    bold: ($) =>
      seq(
        alias(token.immediate("**"), $.bold_marker_start),
        field("content", repeat1($._inline_item)),
        alias(token.immediate("**"), $.bold_marker_end),
      ),
    italic: ($) =>
      seq(
        alias(token.immediate("*"), $.italic_marker_start),
        field("content", repeat1($._inline_item)),
        alias(token.immediate("*"), $.italic_marker_end),
      ),
    bold_italic: ($) =>
      seq(
        alias(token.immediate("***"), $.bold_italic_marker_start),
        field("content", repeat1($._inline_item)),
        alias(token.immediate("***"), $.bold_italic_marker_end),
      ),

    // Common Tokens
    _newline: ($) => "\n",
    _eof: ($) => token(prec(-10, /\0/)), // Special EOF token, though Tree-sitter handles EOF implicitly.
    // Useful if a rule *must* be at the very end.
  },
});
