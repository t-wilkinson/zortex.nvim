# Search

`:ZortexSearch` (`<leader>zz`) searches every note by its structure: the
words you type match a section's path, from the article down to the section
itself. The same search runs on the web (`/search`). Scores, settings and
search history are in [Architecture.md](Architecture.md#ui-layer)
("Structural search").

## Modes

`<M-t>` in the picker cycles the three modes; `ui.search.default_mode` picks
the one `:ZortexSearch` opens in. The picker's title shows its keys;
`ui.search.keys` changes them (`keys = { cycle_mode = "<M-m>" }` when your
terminal or zellij takes `<M-t>`; `false` turns one off). Pick a key the
picker leaves free: `<C-t>` opens the result in a tab in telescope, snacks
and fzf-lua.

| Mode      | Opens with                            | Finds                                                                   |
| --------- | ------------------------------------- | ----------------------------------------------------------------------- |
| `section` | `:ZortexSearch`, `<leader>zz`         | sections whose path matches the words, then lines containing every word |
| `article` | `:ZortexSearchArticles`, `<leader>zZ` | article names only                                                      |
| `text`    | `:ZortexSearchText`, `<leader>z/`     | every line containing the prompt as typed, headings and `@@` lines too  |

The web app's search page has all three (Sections, Articles, Text).

## Words match a path, in order

A section's path is its article, then its headings, bold headings and labels
down to the section itself (`Projects › 1 Programming › 1.4 - zortex`).

- Words match the path **in order**: earlier words on ancestors, the **last
  word on the section itself**. Consecutive words may match the same part.
- `2 4` finds `1 › 2 › 3 › 4`, `2 › 4` and `2 › 3 › 4`; not `4 › 2`, and not
  `2 › 4 › 5` (the last word must be on the section).
- A word matches a part exactly, as a prefix or anywhere inside it; exact
  matches rank higher. Matching ignores case.
- An article's names count: its `@@` aliases and its **file name**
  (`okr` finds `@@Objectives` in `okr.zortex`).
- The direct sub-sections of a match are listed under it.
- After the sections come the other lines that contain every word, each
  shown as `Article › line`.

| Word               | Matches                                         |
| ------------------ | ----------------------------------------------- |
| `plain`            | any part of the path                            |
| `@@name`           | articles only                                   |
| `#name`            | headings only                                   |
| `:name`            | labels only                                     |
| `*name`            | bold headings only                              |
| `@@`, `#`, … alone | any section of that type                        |
| `a_b`, `a\ b`      | one word containing a space (`1.4_-_zortex`)    |

## Ranking

Better word matches rank first (exact, then prefix, then inside), and
articles rank above headings, which rank above bold headings and labels.
Results from one note stay together in document order, so parents sit above
their children; live notes come before archived ones (marked `(archive)`).
Places you often open from search rank a little higher
(kept per machine, outside the notes), never above a better match. The web app keeps
its own history, in its `-data` folder (`search_history.json`), so a synced
notes folder never has two programs writing one file.

## Plain text mode

The whole prompt, spaces included, is one literal string: `#`, `@@`, `:`,
`*` and `_` are ordinary characters. Smart case: case-insensitive unless the
prompt has a capital letter. A note whose file name contains the prompt
comes first, by its article line, marked `(file <name>)`. Results are lines,
live notes before archived ones, then in document order; opening one puts
the cursor on the match.

## Examples

| Query                | Finds                                                                     |
| -------------------- | ------------------------------------------------------------------------- |
| `p`                  | the Projects note first (`@@P` is an exact alias), its sections in order  |
| `1.4 zortex`         | the section `1.4 - zortex` and the sections under it                      |
| `programming zortex` | `zortex` sections under a `Programming` heading                           |
| `#habits`            | headings named like `habits`                                              |
| `@@proj #1.4`        | `1.4` headings in articles named like `proj`                              |
| `:notes`             | labels named like `notes`                                                 |
| `car subaru`         | `subaru` sections under `car`, then any lines with both words             |
| `okr` (article mode) | the Objectives article, by its file name                                  |

## In the picker

`<CR>` opens the result at its line (split, vsplit and tab with the picker's
own keys), `<C-o>` creates a note named after the query
(`2026-10-15.042.zortex`; the web file browser hides these generated names
until "show all"), and `<M-t>` changes mode. The preview shows the note with
the section or line marked.

## Moving things with it

`:ZortexMove` (`<leader>zM`) opens the same picker to choose where the
section under the cursor (a heading, bold heading or label and everything
in it), or the line with the lines nested under it, goes (on a section it
first offers to rename it: keep the name to pick a place). Links to what
moves are rewritten where they would no longer find it. A range or a
visual selection moves exactly those lines. Here every section is offered
whatever the number of words (a one-word search finds `### 6.3: Homelab`
too), and there is no new-note key.

| Picked | It lands |
|---|---|
| a heading or note, moving a heading section | last among its sub-sections, one level below it (`#` under a note); a blank line around it |
| a section, moving anything else | at the end of the section's own lines, before its first sub-section, indented like them (a label's lines start at the label's indent) |
| a line (a list item) | after the lines nested under it, one step (2 spaces) deeper |

A heading can't go under a label or a line (it would end that label's
section instead of joining it), nor a section into itself, nor anything
into a code block. The order of a section's lines stays yours: things always
land at the end, so move a line within the section by hand afterwards. Links
into what moved keep working when they name it by a path that still leads
there; the message counts them, and `:ZortexBrokenLinks` lists any that
broke.
