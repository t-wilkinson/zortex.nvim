Here is a **complete format structure and specification** for building a **Tree-sitter parser** for a custom markup language that closely resembles Markdown, but with extended syntax for semantic linking, tagging, and structured organization.

---

## 📄 File Format Grammar Overview

This markup format is hierarchical, semantically rich, and used for knowledge organization. It consists of five main syntactic elements:

1. **Article Headers**
2. **Tags**
3. **Content Blocks** (Headings, Labels, Paragraphs, Lists, etc.)
4. **Link Types** (custom intra-article, inter-article, and standard markdown)
5. **Formatting Elements** (bold, italic, code, LaTeX, etc.)

Each of these must be explicitly handled by the Tree-sitter grammar and parsed into a structured AST.

---

## 🌲 Tree-Sitter Parser Design Specification

### Root Node: `document`

```bnf
document ::= article_headers tags? blank_lines? body
```

---

## 1. 📰 Article Headers

```bnf
article_headers ::= article_header+
article_header  ::= "@@" article_name newline
article_name    ::= /.+/
```

- **Required**: At least one per file.
- **Syntax**: Begins with `@@` and followed by the article name or alias.
- **Multiple headers** are permitted (aliases).

### AST Nodes:

```json
(article_header
  name: (text))
```

---

## 2. 🏷️ Tags

```bnf
tags ::= tag_line*
tag_line ::= "@" tag_name newline
tag_name ::= /[^\s]+/
```

- **Optional**.
- Used for grouping articles.

### AST Nodes:

```json
(tag
  name: (text))
```

---

## 3. ⬜ Blank Lines

```bnf
blank_lines ::= blank_line*
blank_line ::= "\n"
```

- Ignored structurally but required to separate headers from content.

---

## 4. 📚 Body Content

```bnf
body ::= block+
block ::= heading
        | label
        | paragraph
        | list
        | code_block
        | latex_block
        | blank_line
```

---

## 5. 🧩 Headings

```bnf
heading ::= heading_marker heading_text newline
heading_marker ::= /#+/
heading_text   ::= / .+/
```

- Uses `#`, `##`, etc. followed by a space and heading text.

### AST Node:

```json
(heading
  level: (number)
  text: (text))
```

---

## 6. 🏷️ Labels

```bnf
label ::= label_name ":" newline
label_name ::= /[A-Za-z0-9 ]+/
```

- Acts like metadata or section identifier.

### AST Node:

```json
(label
  name: (text))
```

---

## 7. 📄 Paragraphs

```bnf
paragraph ::= inline+ newline*
inline ::= formatted_text
         | inline_code
         | link
         | text
```

### AST Node:

```json
(paragraph
  content: (inline*))
```

---

## 8. 🔗 Links

This grammar has **3 link styles**:

1. **Article-only**: `[Article]`
2. **Subpath**: `[Article/#Heading]`, `[Article/:Label]`, `[/LocalHeading]`
3. **Markdown URL**: `[text](url)`

```bnf
link ::= "[" link_text "]"
       | "[" link_text "]" "(" url ")"

link_text ::= /[^]]+/
url       ::= /[^)]+/
```

### AST Node:

```json
(link
  type: (article|subheading|label|markdown)
  target: (text)
  anchor: (optional text))
```

---

## 9. 📝 Lists

### Bulleted Lists

```bnf
list ::= list_item+
list_item ::= "- " inline+ newline
```

### Numbered Lists

```bnf
list_item ::= /\d+\. / inline+ newline
```

- **Nested lists** (optional): indentation-aware.

---

## 10. 🔢 Inline Code, Code Blocks

````bnf
inline_code ::= "`" /[^`]+/ "`"
code_block ::= "```" language? newline code_content "```"
language ::= /[a-zA-Z0-9]+/
code_content ::= /(.|\n)*?/
````

---

## 11. 🧮 LaTeX / Math Blocks

### Inline LaTeX

```bnf
latex_inline ::= "$" /[^$]+/ "$"
```

### Block LaTeX

```bnf
latex_block ::= "$$" /(.|\n)*?/ "$$"
```

---

## 12. ✨ Formatting

- **Bold**: `**text**`
- **Italic**: `*text*`
- **Bold Italic**: `***text***`

```bnf
formatted_text ::= bold | italic | bolditalic
bolditalic ::= "***" text "***"
bold       ::= "**" text "**"
italic     ::= "*" text "*"
```

---

## 13. 🧠 Examples of Composite Parsing

### Headings with Nested Content

```markdown
# Services

## Compute

AWS Lambda: Run code without thinking about servers
```

- Should parse headings hierarchically, with paragraphs or label-texts under each.

### Links

```markdown
[Calculus/#Space]
[Calculus/:Vector Field]
[/#Focus]
```

- Split into components: article name, anchor type (heading or label), local/global.

---

## 📂 Optional Additions

- YAML front-matter (if added later) can be a preamble and separated via `---`.

---

## 🛠️ Summary of Node Types

| Node             | Description                       |
| ---------------- | --------------------------------- |
| `document`       | Root node                         |
| `article_header` | Main and alias titles             |
| `tag`            | Tag identifiers                   |
| `heading`        | One or more `#` symbols           |
| `label`          | Label definitions (key:)          |
| `paragraph`      | Plain text and inline elements    |
| `link`           | Article, heading, label, or URL   |
| `inline_code`    | Surrounded by single backticks    |
| `code_block`     | Fenced triple-backtick code block |
| `latex_inline`   | Inline LaTeX expression `$...$`   |
| `latex_block`    | Block LaTeX expression `$$...$$`  |
| `list_item`      | List elements                     |
| `formatted_text` | Bold, italic, etc.                |

---

## 📌 Implementation Notes for the Developer

- Define _precedence rules_ for overlapping tokens (like `*`, `**`, `***`).
- Use Tree-sitter’s _external scanner_ for handling non-trivial block delimiters (like LaTeX or code).
- Pay special attention to line start anchors (e.g., `@@`, `@`, `#`) to avoid ambiguity in inline contexts.
- Normalize escaped characters inside inline formats and links.
- Maintain cross-linking ability by parsing article/heading/label anchors into resolvable metadata.

---

Would you like a working Tree-sitter grammar template scaffold in JavaScript or a `.grammar.js` boilerplate next?
