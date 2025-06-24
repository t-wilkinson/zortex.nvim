// Zortex Tree-sitter Grammar (grammar.js) - Inline Content Conflict Fix

// Precedence levels for resolving inline ambiguities
const PRECEDENCE_LEVEL_EMPHASIS = 1;
const PRECEDENCE_LEVEL_LINK = 10;

// prettier-ignore
module.exports = grammar({
  name: 'zortex',

  extras: $ => [/\s+/], // Corrected: Allow all whitespace as extras

  conflicts: $ => [
    [$._list_marker, $._star_delimiter]
  ],

  rules: {
      // ---------------------------------------------------------------------
      // Document Structure
      // ---------------------------------------------------------------------
      document: $ => seq(
          // Metadata Section - order is important here
          $.article_name, // The first @@ line is the article name
          repeat($.article_alias),  // Subsequent @@ lines are aliases
          repeat($.tag_line),       // @ lines are tags

          // Content Section
          repeat($._block_content_item) // All other content blocks
      ),

      // A block content item can be a content block or a blank line
      _block_content_item: $ => choice(
          $._content_block,
          $._blank_line_explicit // Using an explicit blank line rule for clarity in sequences
      ),

      _blank_line_explicit: $ => prec.left(repeat1($._newline)),

      // ---------------------------------------------------------------------
      // Metadata Rules (consume their own newlines)
      // ---------------------------------------------------------------------
      article_name:  $ => seq('@@', field('name',  $._text_to_eol), $._newline),
      article_alias: $ => seq('@@', field('alias', $._text_to_eol), $._newline),
      tag_line:      $ => seq('@',  field('tag',   $._text_to_eol), $._newline),

      // ---------------------------------------------------------------------
      // Content Blocks (these do not include metadata items handled above)
      // ---------------------------------------------------------------------
      _content_block: $ => choice(
          $.heading,
          $.paragraph,
          $.fenced_code_block,
          $.latex_block,
          $.list,
          $.label_standalone,
          $.label_with_text
          // _blank_line_explicit is handled in _block_content_item
      ),

      // ---------------------------------------------------------------------
      // Helper Rules - Basic
      // ---------------------------------------------------------------------
      _text_to_eol: $ => /[^\n\r]+/,
      _newline: $ => /\r?\n/,

      // ---------------------------------------------------------------------
      // Headings
      // ---------------------------------------------------------------------
      heading: $ => choice(
          $.heading1,
          $.heading2,
          $.heading3,
          $.heading4,
          $.heading5,
          $.heading6
      ),

      heading1: $ => seq('#', ' ', field('content', $._inline_content_no_newline), $._newline),
      heading2: $ => seq('##', ' ', field('content', $._inline_content_no_newline), $._newline),
      heading3: $ => seq('###', ' ', field('content', $._inline_content_no_newline), $._newline),
      heading4: $ => seq('####', ' ', field('content', $._inline_content_no_newline), $._newline),
      heading5: $ => seq('#####', ' ', field('content', $._inline_content_no_newline), $._newline),
      heading6: $ => seq('######', ' ', field('content', $._inline_content_no_newline), $._newline),

      // ---------------------------------------------------------------------
      // Paragraphs and Inline Content
      // ---------------------------------------------------------------------
      paragraph: $ => prec.right(repeat1(
          seq($._inline_content, $._newline)
      )),

      _inline_content: $ => prec.right(repeat1(choice( // Added prec.right for greedy matching
          $._word,
          $.emphasis,
          $.strong_emphasis,
          $.bright_bold_emphasis,
          $.inline_code,
          $.inline_latex,
          $.zortex_link,
          $.autolink,
          $.text_punctuation,
          $.escaped_char
      ))),

      _inline_content_no_newline: $ => prec.right(repeat1(choice( // Also add prec.right here for consistency
          $._word,
          $.emphasis,
          $.strong_emphasis,
          $.bright_bold_emphasis,
          $.inline_code,
          $.inline_latex,
          $.zortex_link,
          $.autolink,
          $.text_punctuation_inline,
          $.escaped_char
      ))),

      _word: $ => /\S+/,

      text_punctuation: $ => choice('.', ',', ';', ':', '?', '!'),
      text_punctuation_inline: $ => choice('.', ',', ';', '?', '!'),

      escaped_char: $ => token(prec(1, seq('\\', /./))),

      // ---------------------------------------------------------------------
      // Labels
      // ---------------------------------------------------------------------
      _label_text_content: $ => /[^:\n\r]+/,

      label_standalone: $ => seq(
          field('name', $._label_text_content),
          ':',
          $._newline
      ),

      label_with_text: $ => seq(
          field('name', $._label_text_content),
          ':',
          // optional(' '), // Covered by `extras: [/\s+/]`
          field('value', $._inline_content_no_newline),
          $._newline
      ),

      // ---------------------------------------------------------------------
      // Emphasis
      // ---------------------------------------------------------------------
      _star_delimiter: $ => '*',
      _double_star_delimiter: $ => '**',
      _triple_star_delimiter: $ => '***',

      emphasis: $ => prec.dynamic(PRECEDENCE_LEVEL_EMPHASIS, seq(
          alias($._star_delimiter, $.emphasis_delimiter),
          field('content', $._inline_content_no_star),
          alias($._star_delimiter, $.emphasis_delimiter)
      )),

      strong_emphasis: $ => prec.dynamic(PRECEDENCE_LEVEL_EMPHASIS + 1, seq(
          alias($._double_star_delimiter, $.emphasis_delimiter),
          field('content', $._inline_content_no_double_star),
          alias($._double_star_delimiter, $.emphasis_delimiter)
      )),

      bright_bold_emphasis: $ => prec.dynamic(PRECEDENCE_LEVEL_EMPHASIS + 2, seq(
          alias($._triple_star_delimiter, $.emphasis_delimiter),
          field('content', $._inline_content_no_triple_star),
          alias($._triple_star_delimiter, $.emphasis_delimiter)
      )),

      _inline_content_no_star: $ => prec.right(repeat1(choice( // Added prec.right
          $._word, $.strong_emphasis, $.bright_bold_emphasis, $.inline_code, $.inline_latex, $.zortex_link, $.autolink, $.text_punctuation, $.escaped_char,
          token(prec(-1, /[^ *\n\r\\]+/)) // Text not containing star, newline, or backslash
      ))),
      _inline_content_no_double_star: $ => prec.right(repeat1(choice( // Added prec.right
          $._word, $.emphasis, $.bright_bold_emphasis, $.inline_code, $.inline_latex, $.zortex_link, $.autolink, $.text_punctuation, $.escaped_char,
          token(prec(-1, /[^ *\n\r\\]+/))
      ))),
      _inline_content_no_triple_star: $ => prec.right(repeat1(choice( // Added prec.right
          $._word, $.emphasis, $.strong_emphasis, $.inline_code, $.inline_latex, $.zortex_link, $.autolink, $.text_punctuation, $.escaped_char,
          token(prec(-1, /[^ *\n\r\\]+/))
      ))),

      // ---------------------------------------------------------------------
      // Code Blocks
      // ---------------------------------------------------------------------
      inline_code: $ => seq(
          '`',
          field('content', optional(token.immediate(/[^`\n\r]+/))),
          '`'
      ),

      fenced_code_block: $ => seq(
          alias(/`{3,}/, $.code_fence_start_delimiter),
          field('language', optional(alias(/[a-zA-Z0-9_\-\+]+/, $.language_name))),
          $._newline,
          field('content', optional($._code_block_content)),
          // optional($._newline), // Allow newline before closing fence if needed
          alias(/`{3,}/, $.code_fence_end_delimiter),
          $._newline // Fenced code block should end with a newline to be a block
      ),

      _code_block_content: $ => repeat1( // Content lines, not including the final fence line
          prec.dynamic(-1, seq($._text_to_eol, $._newline))
      ),


      // ---------------------------------------------------------------------
      // LaTeX Blocks
      // ---------------------------------------------------------------------
      _latex_span_start: $ => '$',
      _latex_span_close: $ => '$',
      _double_dollar_delimiter: $ => '$$',

      inline_latex: $ => seq(
          alias($._latex_span_start, $.latex_delimiter),
          field('content', repeat(choice(
              token.immediate(/[^\$\s\n\r\\]+/),
              $._word,
              $.escaped_char
          ))),
          alias($._latex_span_close, $.latex_delimiter)
      ),

      latex_block: $ => seq(
          alias($._double_dollar_delimiter, $.latex_block_delimiter_start),
          $._newline,
          field('content', repeat(choice( // Content lines
              prec.dynamic(-1, seq($._text_to_eol, $._newline))
          ))),
          alias($._double_dollar_delimiter, $.latex_block_delimiter_end),
          $._newline // LaTeX block should end with a newline
      ),

      // ---------------------------------------------------------------------
      // Lists
      // ---------------------------------------------------------------------
      list: $ => prec.left(repeat1($.list_item)),

      list_item: $ => seq(
          field('marker', $._list_marker),
          ' ',
          field('content', $._inline_content),
          $._newline,
          optional($.list)
      ),

      _list_marker: $ => choice('-', '+', '*'),

      // ---------------------------------------------------------------------
      // Links
      // ---------------------------------------------------------------------
      autolink: $ => token(prec(1, /https?:\/\/[^\s\[\]()<>'""]+/)),

      zortex_link: $ => prec.dynamic(PRECEDENCE_LEVEL_LINK, choice(
          $._internal_label_link,
          $._internal_article_anchor_link,
          $._internal_article_link
      )),

      _link_content_char: $ => /[^\]\\]/,
      _link_text: $ => repeat1(choice($._link_content_char, $.escaped_char)),

      _internal_label_link_content: $ => $._link_text,
      _internal_label_link: $ => seq(
          '[/:',
          field('label_name', $._internal_label_link_content),
          ']'
      ),

      _internal_article_name_content: $ => alias(repeat1(choice(/[^\]#:\/\\]/, $.escaped_char)), $.article_identifier),
      _internal_article_link: $ => seq(
          '[',
          field('article_name', $._internal_article_name_content),
          ']'
      ),

      _internal_anchor_target_content: $ => $._link_text,
      _internal_article_anchor_link: $ => seq(
          '[',
          field('article_name', $._internal_article_name_content),
          field('anchor_type', choice('/#', '/:', '/')),
          field('target', $._internal_anchor_target_content),
          ']'
      )
  }
});
