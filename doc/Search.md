# Zortex Structural Search — Requirements & Behavior Specification

## Overview

The search is a Telescope-based dynamic picker (`finders.new_dynamic`) that queries across all `.zortex` note files. Every keystroke re-runs the full search pipeline. Results are divided into two ranked tiers: **section results** first, **line results** after. The pipeline has three stages: tokenization → scope resolution → content search.

---

## Document Structure

Zortex files are parsed into a tree of typed nodes. The relevant node types are:

| Node type      | Source syntax             | Notes                                       |
| -------------- | ------------------------- | ------------------------------------------- |
| `article`      | `@@Article Name`          | Top-level document unit; multiple per file  |
| `heading`      | `# H1`, `## H2`, `### H3` | Levels 1–6; level stored on node            |
| `bold_heading` | `**Bold Label**:`         | Semantic "bold label"; level 7 in tree      |
| `label`        | `Label:`                  | Key-value heading; level 8+indent           |
| `tag`          | `@TagName`                | File-level single-`@` lines; not tree nodes |

All non-structural lines (bullets, tasks, plain text, numbered lists, etc.) are **content lines** and are only surfaced by the line search backend.

---

## Tokenization

The query string is split on unescaped spaces. A backslash followed by a space (`\ `) is treated as a **literal space** within the current token and does not split.

Each token is classified by its prefix:

| Prefix | Token type     | Example          | Matches against          |
| ------ | -------------- | ---------------- | ------------------------ |
| `@@`   | `article`      | `@@Zettelkasten` | Article node names       |
| `@`    | `tag`          | `@productivity`  | Tag lines (`^@...`)      |
| `#`    | `heading`      | `#Health`        | Heading nodes            |
| `:`    | `label`        | `:Status`        | Label nodes              |
| `*`    | `bold_heading` | `*Diagnosis`     | Bold heading nodes       |
| none   | `general`      | `diabetes`       | Node text + line content |

A token with only its prefix character and no following text is discarded.

---

## Scope Resolution

Before any content matching occurs, the full token list is split into four buckets: `article_tokens`, `tag_tokens`, `struct_tokens` (heading/label/bold_heading), and `general_tokens`. The first three buckets define the **search scope**; `general_tokens` are passed to the content-search backends unchanged.

### Step 1 — Article + Tag Filtering

If any `@@` or `@` tokens are present, the scope is narrowed to specific article nodes. Otherwise the scope covers entire files.

**Article tokens (`@@`) — OR logic.** A candidate article node is included if its name is a prefix match for _any_ `@@` token. `@@Art` matches an article named `Arthur Schopenhauer` but not `K-mart Art`.

**Tag tokens (`@`) — AND logic.** After article filtering, each remaining article must contain _every_ `@` tag token. A tag matches if a line within the article's range begins with `^@` and its text is a prefix match for the tag token. `@@Health @urgent` returns only articles named Health-something that also contain an `@urgent` tag line.

Multiple `@@` tokens together are OR: `@@Health @@Fitness` returns all articles matching either prefix.

### Step 2 — Structural Narrowing

Structural tokens (`#`, `:`, `*`) are applied **in the order they appear in the query**, one at a time. Each token replaces the current set of scope entries with new entries rooted at matching child nodes.

For each existing scope entry, the tree is walked from the current scope root. The walk finds all nodes whose type and text match the structural token, using prefix matching. **The walk does not recurse into a node that already matched** — this ensures `#H1 #H2` finds nodes named H2 that live _inside_ a node named H1, rather than all H2s across the whole tree.

`#H1 #H2` — finds heading H2 nested under heading H1. Order matters for ambiguity resolution; the first token narrows first.

Multiple structural tokens of the _same_ type (other than `@@`) also narrow hierarchically. `#Overview #Summary` looks for a heading Summary inside a heading Overview.

After each structural token is applied, every matched node becomes a new scope entry with `start_line` and `end_line` set to that node's bounds. Subsequent tokens and content backends operate only within those bounds.

### Scope Entry Shape

```
scope_entry = {
  filepath   : string          -- absolute path to the file
  lines      : string[]        -- all lines of the file (1-indexed)
  tree       : Section         -- root node of the full file tree
  start_line : number          -- inclusive lower bound (1-indexed)
  end_line   : number          -- inclusive upper bound
  scope_node : Section | nil   -- nil when scope is an entire file
}
```

---

## Matching Rules

### Smart-Case

All pattern matching (structural prefix matching and general content matching) is **smart-case**: case-insensitive if the token text contains no uppercase letters; case-sensitive if it contains at least one uppercase letter.

### Structural Token Matching

A structural token matches a node when:

1. The node type equals the token type exactly (`#` only matches `heading`, `*` only matches `bold_heading`, etc.).
2. The node's text begins with the token text (prefix match, smart-case).

### General Token Matching (Sections)

A general token matches a node if the token text appears anywhere in the node's `.text` field OR anywhere in any line within `node.start_line..node.end_line`. Multiple general tokens are **AND**: all must match.

### General Token Matching (Lines)

A general token matches a content line if the token text appears anywhere in that line. Multiple general tokens are **AND**.

### Literal Space

`\ ` within any token (any type) is a literal space character in the match pattern, not a token boundary. `*My\ Label` matches a bold heading node with text `My Label`.

---

## Section Search Backend

Inputs: `scope_entries`, `general_tokens`.

**No general tokens, structural scope present:** Returns the scope node itself plus all of its direct children. This is the "browse this section" case — typing `@@Health #Diagnosis` immediately shows the Diagnosis heading and its direct sub-sections.

**No general tokens, no structural scope:** Returns nothing. An empty query against all files is too broad to be useful.

**General tokens present:** Traverses each scope entry's subtree depth-first. Collects the **deepest** nodes that satisfy `node_content_matches`. Parent nodes are suppressed if any of their children already matched — this prevents a broad ancestor heading from appearing alongside the specific sub-node that is the real match.

The scope node itself is never added as a result (it is the boundary, not a target).

---

## Line Search Backend

Inputs: `scope_entries`, `general_tokens`.

Only runs when general tokens are present. If there are no general tokens, returns nothing.

For each scope entry:

1. Collect the start lines of all structural nodes within the scope into an exclusion set.
2. Iterate over every line in `start_line..end_line`.
3. Skip lines whose line number is in the exclusion set (structural lines are already covered by the section backend).
4. Skip blank lines.
5. Apply AND matching of all general tokens against the line text.
6. If all tokens match, emit a line result.

Line results include the article name for display. When the scope entry has a known `scope_node`, the article name is derived by walking up the parent chain. When the scope covers an entire file (no structural scope), the article is determined by which article node's range contains the line number.

---

## Display

### Section Results

Displayed as a coloured breadcrumb path from the root down to the matched node. Path components are separated by `›` (rendered in `Comment` highlight group). Each component is highlighted with its semantic Zortex highlight group:

| Node type      | Highlight group                    |
| -------------- | ---------------------------------- |
| `article`      | `ZortexArticle`                    |
| `heading`      | `ZortexHeading1/2/3` (capped at 3) |
| `bold_heading` | `ZortexBoldHeading`                |
| `label`        | `ZortexLabel`                      |
| other          | `Normal`                           |

### Line Results

Displayed as `ArticleName › trimmed line content`. The article name uses `ZortexArticle`. The line content is highlighted with the semantic group that matches the line's own syntax:

| Line pattern                                   | Highlight group                 |
| ---------------------------------------------- | ------------------------------- |
| `- [x] ...`                                    | `ZortexTaskDone`                |
| `- [?] ...` (any checkbox)                     | `ZortexTaskText`                |
| `  - Label: text` (list item with colon+space) | `ZortexLabelListText`           |
| `  - Label:` (list item with colon, EOL)       | `ZortexLabelList`               |
| `- ...` (bullet, indent level N)               | `ZortexBullet1`–`ZortexBullet4` |
| `1. ...`                                       | `ZortexNumberList`              |
| other                                          | `Normal`                        |

Bullet indent level is `floor(leading_spaces / 2) + 1`, capped at 4.

### Result Ordering

Section results are always listed before line results. Within each tier, order is determined by the Telescope generic sorter applied to the `ordinal` field (breadcrumb string for sections, raw line text for lines). No further custom ranking is applied.

---

## Previewer

Uses `previewers.new_buffer_previewer`. On selection change:

1. The full file is loaded into the preview buffer.
2. `highlights.highlight_buffer` applies Zortex syntax highlighting.
3. For **section results**: every line in `node.start_line..node.end_line` receives the `Visual` highlight; the first line additionally receives `CursorLine`.
4. For **line results**: only the matched line receives `CursorLine`.
5. The preview window scrolls to center the focus line (`zz`).

---

## Navigation

Pressing Enter on any result closes the picker, opens the file with `:edit`, and positions the cursor at the relevant line number (`node.start_line` for sections, `lnum` for lines), then centers the view with `zz`.

---

## Query Examples

| Query                           | Behaviour                                                                              |
| ------------------------------- | -------------------------------------------------------------------------------------- |
| `diabetes`                      | All sections/lines across all files containing "diabetes"                              |
| `@@Health`                      | Health article node + its direct heading children                                      |
| `@@Health diabetes`             | Deepest sections and content lines within Health articles that contain "diabetes"      |
| `@@Health #Diagnosis`           | Diagnosis heading(s) within Health articles + their direct children                    |
| `@@Health #Diagnosis treatment` | Content within Diagnosis headings (in Health) matching "treatment"                     |
| `@@Health @@Fitness exercise`   | Content in Health- or Fitness-prefixed articles matching "exercise"                    |
| `@urgent`                       | All articles containing an `@urgent` tag line; shows their direct children             |
| `@@Health @urgent`              | Health articles that also contain `@urgent`                                            |
| `#Overview #Summary`            | Summary headings nested inside Overview headings, across all files                     |
| `*My\ Label`                    | Bold heading nodes named "My Label" (literal space via escape)                         |
| `Diabetes Type\ 2`              | Sections/lines containing both "Diabetes" and "Type 2" (literal space in second token) |
| `@@Health :Status open`         | Content lines/sections under Status labels in Health articles containing "open"        |

---

## Planned Future Extensions (not yet implemented)

- Mode toggle within the picker: section-only search vs. text-only search vs. combined (current default).
- Additional structural token types as the document model grows.
