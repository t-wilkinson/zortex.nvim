/**
 * @file Zortex grammar for tree-sitter
 * @author Trey Wilkinson <winston.trey.wilkinson@gmail.com>
 * @license MIT
 */

/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

// grammar.js
module.exports = grammar({
  name: "custom_markdown",

  // Whitespace that can appear anywhere (excluding newlines initially, handled by blocks)
  extras: ($) => [
    /[ \t]+/, // Allow spaces and tabs between tokens on the same line
  ],

  // Rules that might conflict and need explicit resolution
  conflicts: ($) => [
    [$._text_inline, $.link],
    [$._text_inline, $.formatted_text], // To ensure formatting markers are preferred
    [$._text_inline, $.inline_code],
    [$._text_inline, $.latex_inline],
    // Potentially, if list items can be very simple and resemble plain paragraph lines.
    // The structure of list items (marker + space) should generally prevent this.
  ],

  // Precedence for ambiguous parsing, e.g., *** vs ** and *
  precedences: ($) => [
    [$.bold_italic, $.bold, $.italic], // *** wins over **, which wins over *
    // Block-level precedence: more specific block starters should win
    [$.code_block, $.latex_block, $.list, $.heading, $.label, $.paragraph],
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
    article_name: ($) => token(prec(1, /[^\n]+/)),

    // 2. Tags
    tags: ($) => repeat1($.tag_line),
    tag_line: ($) => seq("@", field("name", $.tag_name), $._newline),
    tag_name: ($) => token(/[^\s@\n]+/),

    // 3. Blank Lines (structural separator)
    _blank_lines: ($) => repeat1($._blank_line_token), // Use a named token for clarity
    _blank_line_token: ($) => alias($._newline, $.blank_line), // Alias for semantic meaning in tree

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
        $._blank_line_token, // Allow blank lines between blocks in the body
      ),

    // 5. Headings
    heading: ($) =>
      seq(
        field("marker", $.heading_marker),
        " ", // Required space after marker
        field("text", $.heading_text),
        $._newline, // Headings are line-based
      ),
    heading_marker: ($) => token(/#+/),
    heading_text: ($) =>
      repeat1(
        // Content of the heading
        choice(
          $.link,
          $.formatted_text,
          $.inline_code,
          $.latex_inline,
          $._escaped_char_generic, // Allow escaped characters
          token(prec(-1, /[^#*`$\[\n\\]+/)), // General text, avoiding other inline starters
        ),
      ),

    // 6. Labels
    label: ($) => seq(field("name", $.label_name), ":", $._newline),
    label_name: ($) => token(/[A-Za-z0-9][A-Za-z0-9 ]*/),

    // 7. Paragraphs
    // A paragraph is a sequence of inline content, terminated by a newline.
    // It's distinguished from other blocks by not starting with their specific markers.
    paragraph: ($) =>
      prec.dynamic(-1, seq(repeat1($._inline_item), $._newline)),

    // Unified inline item definition
    _inline_item: ($) =>
      choice(
        $.link,
        $.formatted_text,
        $.inline_code,
        $.latex_inline,
        $._escaped_char_generic,
        $._text_inline, // General text
      ),

    // General text token for inline content
    // It should not consume characters that start other inline elements or block elements at line start.
    _text_inline: ($) => token(prec(-2, /([^\[*`$\n\\]|\\.)+/)), // Lowest precedence text

    // Escaped character (generic)
    _escaped_char_generic: ($) => token.immediate(/\\./), // Escape any character, immediate to bind tightly

    // 8. Links
    link: ($) =>
      choice(
        // Markdown style: [text](url)
        seq(
          "[",
          field("text", repeat1($._link_text_content)),
          "]",
          "(",
          field("url", repeat($._url_content)),
          ")",
        ),
        // Article/Subpath style: [Article/#Heading], [Article/:Label], [/LocalHeading], [Article]
        seq("[", field("path", repeat1($._link_text_content)), "]"),
      ),
    _link_text_content: ($) =>
      choice(token.immediate(/[^\]\\]+/), $._escaped_char_generic),
    _url_content: ($) =>
      choice(token.immediate(/[^)\s\\]+/), $._escaped_char_generic),

    // 9. Lists
    list: ($) => repeat1(choice($.bullet_list_item, $.numbered_list_item)),

    bullet_list_item: ($) =>
      seq(
        field("marker", choice("-", "*", "+")),
        " ",
        repeat1($._inline_item),
        $._newline,
        // Note: Nested lists typically require indentation handling (external scanner).
      ),
    numbered_list_item: ($) =>
      seq(field("marker", /\d+\./), " ", repeat1($._inline_item), $._newline),

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
        field("content", optional($._fenced_content)),
        "```",
        $._newline,
      ),
    language_name: ($) => token.immediate(/[a-zA-Z0-9]+/), // No spaces around language name

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
        field("content", optional($._fenced_content)),
        "$$",
        $._newline,
      ),

    // Helper for content of fenced blocks (code and LaTeX)
    // This captures lines until the closing fence. For robustness with escaped fences,
    // an external scanner is better.
    _fenced_content: ($) =>
      repeat1(
        choice(
          token.immediate(/[^\n]+/), // Any character except newline
          $._newline, // Allow newlines within the fenced content
        ),
      ),

    // 12. Formatting (Bold, Italic, Bold-Italic)
    formatted_text: ($) => choice($.bold_italic, $.bold, $.italic),

    bold: ($) =>
      seq(
        alias(token.immediate("**"), $.bold_marker_start),
        field("content", repeat1($._inline_item_for_formatting)), // Content of bold
        alias(token.immediate("**"), $.bold_marker_end),
      ),
    italic: ($) =>
      seq(
        alias(token.immediate("*"), $.italic_marker_start),
        field("content", repeat1($._inline_item_for_formatting)), // Content of italic
        alias(token.immediate("*"), $.italic_marker_end),
      ),
    bold_italic: ($) =>
      seq(
        alias(token.immediate("***"), $.bold_italic_marker_start),
        field("content", repeat1($._inline_item_for_formatting)), // Content of bold_italic
        alias(token.immediate("***"), $.bold_italic_marker_end),
      ),

    // Content within formatting: cannot directly contain the *same* level of formatting marker
    // but can contain others or general text. This helps avoid trivial infinite recursion.
    // This is a common pattern but can be complex.
    // A simpler approach is to allow any _inline_item and rely on precedence,
    // but this can sometimes lead to unexpected parse trees for nested formatting.
    _inline_item_for_formatting: ($) =>
      choice(
        // $.link, // Links can be inside formatting
        // $.inline_code, // Inline code can be inside
        // $.latex_inline, // Inline LaTeX can be inside
        // $.bold, // Allow bold inside italic/bold_italic (if not ***)
        // $.italic, // Allow italic inside bold/bold_italic (if not ***)
        // $.bold_italic, // Potentially allow bold_italic inside others (complex)
        // For now, keeping it simpler:
        $.link,
        $.inline_code,
        $.latex_inline,
        $._escaped_char_generic,
        token(prec(-1, /[^\[*`$\n\\]+/)), // Text not starting other markers
        // Adjust this regex if specific markers need to be excluded
        // based on the parent formatting rule.
        // Example: in *italic*, text cannot be *
        // This is where Tree-sitter's GLR parsing helps.
        // The original `_inline_item` might be sufficient with correct precedence.
        // Let's revert to the simpler `_inline_item` and rely on precedence.
        // If issues arise, this is an area for refinement.
      ),

    // Common Tokens
    _newline: ($) => "\n",
  },
});

// Re-assigning _inline_item_for_formatting to _inline_item after definition
// This is a common JS pattern if you need to break a circular dependency in rule definitions,
// or if you decide later that a more general rule is fine.
// In this case, relying on precedence for formatting nesting is generally robust.
// module.exports.rules._inline_item_for_formatting =
//   module.exports.rules._inline_item;
