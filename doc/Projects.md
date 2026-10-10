# Projects

Projects are first-class objects. Each one collects tasks, notes and context
in one place, and the calendar, OKRs and areas link to it.

## What is a project

- **The Projects article** (`projects.zortex`, `@@Projects` / `@@P`) is the root
  project. Every heading inside it is a project; headings below a heading are
  its sub-projects.
- **Standalone projects**: any note with `@P` in its header is a root project
  named after its article, e.g. `@@Flipping` + `@P`. Its headings are
  sub-projects.
- **Own content**: a project's own tasks and notes run from its header line to
  its first sub-project. Container projects have their own tasks too.
- Labels (`Notes:`) and bold headings are content, not sub-projects.
- Archived notes (`z/archive.*.zortex`, or tagged `@Archive`) are ignored.

## Identity

The tree path of clean texts (attributes removed):

| field  | example                                       |
|--------|-----------------------------------------------|
| `path` | `{ "Projects", "1 Programming", "1.4 - zortex" }` |
| `key`  | `Projects/1 Programming/1.4 - zortex`          |
| `link` | `[Projects/#1 Programming/#1.4 - zortex]`      |

## Links

Project links resolve exactly like following a link (`utils/link_resolver`):

- `[P/#1.4 - zortex]`: `P` matches any `@@` alias. `#1.4 - zortex` is a
  case-insensitive prefix match on a heading at any depth.
- `[@P/#Subaru outback]`: `@P` selects notes whose header carries the tag.
- When several headings match, the first in note order is canonical, so a
  parent heading wins over children that share its prefix.

## API

```lua
local P = require("zortex.services.projects")

P.roots()                                  -- one root per source
P.all({ leaf = true, include_done = false, include_roots = false, filter = fn })
P.query({ sort = "score", limit = 10 })    -- score|priority|importance|due|size|remaining|completion|name|path
P.get("Projects/1 Programming/1.4 - zortex")
P.resolve("[P/#1.4 - zortex]")             -- -> project, link result
P.at(bufnr | path | doc, lnum)             -- innermost project containing a line
P.current()                                -- project at the cursor
P.tasks({ include_done = false })          -- every task, each with .project
P.update_progress(bufnr)                   -- write @progress(done/total) on headings

p.name, p.key, p.path, p.link, p.attributes, p.tags, p.aliases
p.parent, p.children, p.depth, p.kind      -- "article" | "heading"
p.file, p.lnum, p.start_line, p.end_line
p:tasks()      p:all_tasks()   p:notes()   p:lines()
p:stats()      -- own: total/done/open, points/points_done/points_open, sizes, completion
p:rollup()     -- same, including sub-projects
p:points()     -- explicit @size(...) wins, else the sum of task points
p:is_done()    p:is_leaf()     p:is_root()
p:walk(fn)     p:fold(fn)      p:ancestors()  p:descendants()
p:schedule({ descendants = true, from = "2026-10-01", to = "2026-10-31" })
p:key_results({ inherit = true })
p:areas({ inherit = true })
```

Sizes come from `@size(xs|sm|md|lg|xl)` (projects may also use `epic`,
`legendary`, `mythic`, `ultimate`). Points are xs=1, sm=2, md=3, lg=5, xl=8,
epic=13, … (`constants.SIZE_POINTS`). Unsized tasks count as `md`.

## Picker

`:ZortexProjects`

| key              | action                    |
|------------------|---------------------------|
| `<CR>`           | open                      |
| `<C-x>` / `<C-v>`| open in split / vsplit    |
| `<C-l>`          | insert the link at the cursor |
| `<C-y>`          | yank the link             |
| `<C-s>`          | cycle sort order          |
| `<C-d>`          | show/hide done projects   |
| `<C-e>`          | leaf projects only        |

## Building blocks

Areas or OKR can reuse these the same way projects do:

- `core/document`: cached snapshot of a note (lines, tree, names, tags).
  Prefers a modified buffer over the file on disk.
- `core/notes`: the note list and header index (`find_by_name`, `find_by_tag`).
- `core/section`: the structural tree, plus `walk`, `find`, `filter`, `fold`,
  and `derive(root, keep, make)`, which builds a domain tree from chosen
  section types (projects keep articles and headings).
- `utils/link_resolver`: `resolve`, `resolve_first`, `resolve_node`, `link_for_node`.

## Tests

```sh
nvim --headless -u NONE -l tests/run.lua           # all
nvim --headless -u NONE -l tests/run.lua projects  # one file
```
