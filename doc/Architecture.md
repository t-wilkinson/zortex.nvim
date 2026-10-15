# Zortex architecture

How the Lua side of zortex.nvim is put together: what each layer is for, how
data moves from a `.zortex` file to a project in a picker, and the rules every
module agrees on. For the projects/areas API reference see
[Projects.md](Projects.md); for the note format, [Syntax.md](Syntax.md).

## Summary

Every note is parsed **once**, by one grammar (`core/syntax`), into a cached
_document_. A document holds the lines, the syntax of every line (what it is,
where its inline spans are), a structural tree, and the header (article names
and tags). Everything else is built on documents:

- **One parser.** Highlighting, folding, the TOC, tasks, the calendar, OKR,
  link extraction, search and the export all read the same syntax; nothing
  re-parses lines with patterns of its own. The grammar is plain Lua with
  conformance fixtures, so it can be ported (or run) outside Neovim.
- **One item type.** Project tasks, calendar entries and key results are all
  list items (`core/item`): marker, optional `Key:`, optional checkbox, text,
  typed attributes.
- **Links** resolve against documents with one resolver. A link means the same
  thing when you follow it, when completion suggests it, and when projects,
  OKRs or the calendar look it up.
- **A link index** records every link in every note and where it resolves,
  persisted in `notes_dir/.z/link_index.json`. Backlinks, project schedules,
  KR → project links and broken-link reports all read it.
- **Projects**, **areas** and **objectives** are _entities_: objects derived
  from sections of the tree, each with a stable key (its tree path) and a
  canonical link.
- **Relations** connect them: calendar entries, key results and area links are
  resolved to entity keys, never compared as link text.
- **The agenda** combines the calendar, due tasks and projects into one query
  plus a `review()` for weekly reviews.
- **Writes** go through a small editing layer (buffer if loaded, otherwise the
  file) as line edits; nothing regenerates a whole note.
- **State** in `notes_dir/.z` (link index, search history, XP, notifications)
  goes through one versioned module (`core/state`).
- **UI** (pickers, completion, preview, mastery tree, calendar, digest, review)
  only reads these APIs. **`zortex.query`** exposes the same model as plain
  data (JSON-safe) for anything outside Neovim.

```
            ┌───────────────────────────────────────────────────────────┐
  UI        │ picker/{search,projects,follow,calendar}  mastery_tree    │
            │ highlights folding toc completion preview review           │
            │ actions.lua ──► commands, keymaps, api.actions, :ZortexHelp│
            └──────────────▲────────────────────────────▲────────────────┘
                           │        query.lua (plain data, export)
            ┌──────────────┴──────────┐   ┌─────────────┴──────────────┐
  Domain    │ services/projects       │   │ services/xp (core, stats,  │
            │ services/areas  okr     │◄──┤  calculator) + stores/xp   │
            │ services/agenda  tasks  │   └────────────────────────────┘
            │ services/search digest  │
            │ stores/calendar         │
            └──────────────▲──────────┘
                           │  entity.registry(spec)
            ┌──────────────┴──────────────────────────────────────────┐
  Core      │ core/entity   core/link_index   core/link               │
            │ core/document ──► core/section (tree)   core/notes      │
            │ core/syntax (the grammar)   core/item (list items)      │
            │ core/workspace (edits)   core/state (.z files)          │
            │ core/event_bus  logger                                  │
            └─────────────────────────────────────────────────────────┘
```

## Notes on disk

The note format (header, sections, items, attributes, inline spans, links,
special notes) is described in [Syntax.md](Syntax.md), whose examples a test
checks against the parser. Notes named `z/archive.*.zortex`, or tagged
`@Archive`, are archived and ignored by link resolution and project lists.

## Core layer

### One structural level scale — `constants.SECTION_HIERARCHY`

| Section      | Level           |
| ------------ | --------------- |
| article      | 0               |
| heading      | 1–6 (`#` count) |
| bold heading | 7               |
| label        | 8 + indent      |
| tag / text   | not structural  |

A section ends at the next section with a level **≤** its own. The tree builder,
breadcrumbs, section navigation, folding and archive merging all use this one
scale. Before this branch there were two scales (0–8 and
10–100), and some modules compared numbers from both.

### Syntax — `core/syntax.lua`

The Zortex grammar, in one module. It is plain Lua (no `vim.*`), returns plain
tables, and is the only code that decides what a line or a span is.

- `parse(lines, { inline })` → `{ version, header, lines, sections, blocks }`.
  `lines[lnum]` is a descriptor: `kind` (`blank`, `article`, `tag`,
  `heading`, `bold_heading`, `label`, `item`, `text`, `fence`, `code`,
  `math_fence`, `math`, `table`, `quote`, `footnote`), `indent`, and for
  sections `section`, `level`, `text` (attributes stripped), `heading`
  (`#` count). Items carry `item` = `{ marker, marker_type, marker_col,
time, key, key_col, mark, mark_col, content_col }`. `content_col` is where
  inline content starts. `sections` are the structural lines in order (the
  header gives **one** article carrying all its `names`); `blocks` are code,
  math and table ranges.
- `classify(line)` classifies a single line (no header or fence context).
- `item(line)` parses a list item; a checkbox needs text after it.
- `inline(line, from, to)` → non-overlapping spans `{ type, s, e, … }` with
  0-based byte columns: `link`, `live_link`, `tag_search`, `markdown`,
  `footnote_ref`, `url`, `filepath`, `attribute`, `code`, `math`, `bold`,
  `italic` (with `children`), `time`. Attributes and file paths must start a
  word (`me@example.com` is not an attribute); single-character brackets
  (`[ ]`, `[x]`) and `[^…]` are not links; `$5 and $6` is not math.
- `span_at(line, col)`, `links(line)`, `walk_spans` for link lookups.
- `parse_header`, `strip_attributes`, `section_text`.

**Conformance fixtures.** `tests/fixtures/ast/*.json` hold the parser's
output for every fixture note plus `tests/fixtures/syntax/sample.zortex`
(every construct). `test_syntax` checks the parser against them; regenerate
with `nvim --headless -u NONE -l tests/gen_ast.lua` after a deliberate
grammar change. Another implementation (for example the web app) can use the
same pairs as its test suite.

### Items — `core/item.lua`

The shared type for anything written as a list item. `Item.from_line(line,
{ lnum, file, info, schema, context })` returns `lnum`, `file`, `raw_text`,
`indent`, `marker`, `marker_type`, `time`, `key`, `mark`, `mark_col`,
`completed`, `body` (after marker, key and checkbox), `text` (attributes
removed) and `attributes` (typed with a `utils/attributes` schema; `task` by
default). `Item.task(line)` returns only items with a checkbox.
`item:with_mark("x")` changes just the checkbox; `item:links()` lists link
definitions.

- **Project tasks** are the checkbox items in a project's own range
  (`doc:items(s, e, { tasks = true })`).
- **Key results** are items keyed `KRn` (`- KR2: [ ] …`).
- **Calendar entries** are the items under a date label
  (`services/calendar_entry`): an entry _is_ its Item, plus `type`
  (task/event/note), `text` without the time prefix, `date_context`,
  `timing` and recurrence (`is_active_on_date`). Its text formats are
  `calendar_entry/format` (`pretty`, `simple`).

### Link grammar — `core/link.lua`

`split` / `parse` / `parse_component` turn a link definition into typed
components (`split` ignores `/` inside parentheses and is shared with
completion). `at(line, col)` is the link under the cursor (from syntax
spans; `@a(...)` resolves to its area link), and `links_on(line)` the plain
`[...]` links on a line. Resolution and link building are in the same
module (next sections); following a link in a buffer (quickfix list,
footnotes, `@[scope/tag]` searches) is `features/links`.

### Sections — `core/section.lua`

`build_tree(lines, ast)` assembles a `Section` tree under a synthetic `root`
from `ast.sections`. Nodes
have `type`, `text` (clean), `level`, `start_line`, `end_line`, `children`,
`parent`, and `names` (article nodes only).

**Generic helpers**, used by search and by entities:

| helper                                                          | does                                                       |
| --------------------------------------------------------------- | ---------------------------------------------------------- |
| `walk(fn)`                                                      | pre-order; return `false` to skip children                 |
| `find(pred)` / `filter(pred)`                                   | first / all matches                                        |
| `fold(fn)`                                                      | post-order aggregation `fn(node, child_results)`           |
| `ancestors()`, `path_texts()`, `get_breadcrumb(sep)`, `depth()` | paths                                                      |
| `get_direct_end_line()`                                         | content before the first child                             |
| `derive(root, keep, make)`                                      | builds a domain tree from chosen node types (see entities) |

### Documents — `core/document.lua`

A `Document` is an immutable snapshot `{ filepath, lines, syntax, tree, names, tags, header }`.

- `Document.from_file(path)` is cached by mtime (seconds + nanoseconds) and size.
- `Document.from_buffer(bufnr)` is cached by `changedtick`.
- `Document.get(path)` **prefers a loaded, modified buffer** over the file, so
  unsaved edits are visible everywhere (project stats, links, OKR).
- `Document.resolve(x)` accepts a Document, a path or a bufnr.
- Methods: `name()`, `has_name()`, `has_tag()`, `article()`, `node_at(lnum)`,
  `node_starting_at(lnum)`, `get_lines()`.
- Syntax access: `info(lnum)` (the line descriptor), `inline(lnum)` (spans,
  parsed on first use), `in_code(lnum)` (inside a fence or math block),
  `items(s, e, { tasks, schema, context })` (core/item Items).

Because snapshots are immutable, anything derived from one (projects, areas)
is cached **on the snapshot**. When the file changes there is a new snapshot,
and the cache goes with the old one.

A note's tree is `Document.get(path).tree`.

### Notes index — `core/notes.lua`

- `files()` lists every note recursively, top-level first then alphabetically,
  without archived notes.
- `index()` is a short-lived (1 s) snapshot `{ files, headers }` (one with
  archived notes, one without), so bulk work (resolving many links) doesn't
  re-stat every file per link.
- `find_by_tag(tag)` is case-insensitive.
- `header(path)` reads **only** the header block, cached by mtime.
- `is_archived(path)` is true for `archive.*` filenames or the `@Archive` tag.

### Links — `core/link.lua`

A link is `/`-separated components resolved **left to right**. Each component
narrows a list of candidates (file + line range):

| Component    | Example                   | Narrows to                                                                                                                                                     |
| ------------ | ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Article      | `P`, `Projects`           | Files declaring the alias, **then** files tagged with it.                                                                                                      |
| Tag          | `@P`                      | Files whose header has the tag. If no file declares it, a line search for `@P`.                                                                                |
| Heading      | `#1.4 - zortex`           | Heading lines whose text **starts with** the text, case-insensitive, at **any depth** in the current range.                                                    |
| Label / bold | `:Fitness`, `*X`          | Line searches.                                                                                                                                                 |
| List item    | `-KR1`, `-Call the bank`  | A list item whose key (`- KR1: …`) or text (checkbox and attributes ignored) starts with the text.                                                             |
| Query        | `%text`                   | Line searches. Case-sensitive only if the query has an uppercase letter.                                                                                       |
| Follow       | `>The Rust Book`          | Links on lines in range whose own text (markdown text, definition, URL, path) or line text starts with the text; `>` alone is every link. Last component only. |

**Parent-relative links**: `[./-Item]` (`./` then `-`, `#`, `:`, `*` or `>`)
is `absolute(def, lines, lnum)`: the first link of the nearest line above
with less indentation that has one (`links_on`, skipping file paths;
relative parents expand first), then `/` and the rest. `resolve` expands it
when given `doc` and `lnum`; callers that read links off lines (link index,
following, preview, the web renderer) pass them. Other `./` links are file
paths (`relative_path`). app/links `Absolute` is the same, checked by the
`lnum` cases of `tests/fixtures/resolve.json`.

**Generated link text** keeps only `[A-Za-z0-9 _-().]`: `component_text`
takes the longest such prefix (with balanced parentheses), so
`#4 Learning & Education` is written `#4 Learning` and still resolves by
prefix. `item_component(line)` gives `-KR1` for keyed items and `-<text>`
otherwise; key results link as `[O/#Current/#3M-2026-Q1 …/-KR1]` and planner
tasks as `[P/#…/-Improve website]`.

**Rules for the result:**

- For a non-final component, the **first match in each file** becomes the new
  range: the section starting at that line (`doc:node_starting_at`).
- Results come back in note order (top-level files first, then line order), and
  `results[1]` is the **canonical** target. So `[P/#1.4]` resolves to the first
  `1.4…` heading, which is the parent of any children sharing that prefix.
- Archived notes are skipped unless a component is `@Archive` or
  `opts.include_archived` is set.
- Local links (`[/…]`) resolve in the current buffer.
- `resolve("@[scope/tags]")` is a tag search (`tag_search(content)`): the
  scope link's results become ranges (a whole note for article and tag
  components, `result.whole`; otherwise `lnum..result.end_line`), and every
  non-blank, non-header line outside code in them matches when its own bare
  `@words` plus those of the section headings above it satisfy the query
  (words: all of them; commas separate alternatives). No scope is the
  current note, `*` every note. Notes about a resource match by their own
  tags only: the lines nested under an item holding a link
  (`is_resource_note`) and the section of a heading that is only a link
  (`is_resource_heading`, which itself takes the tags above it).
- A `-` component compares a list item's text with markdown links replaced
  by their text (`link_text`), so `-The Rust Book` finds
  `- [The Rust Book](…)`; `item_component` writes it that way.
- A `>` component gives one result per matching link (a line with two links
  gives two), each with `result.target`, the link (as `at()` returns it).
  Following the link opens that target instead of the line, from the note it
  is written in: directly when there is one, through `vim.ui.select` (Neovim)
  or the link page (web app) when there are several. Chains of `>` links stop
  after five.

The article-or-tag rule is what lets `[P/…]` mean "the project namespace". It
searches the Projects article first, then every `@P` note, so
`[P/Flipping/#Subaru outback]` and `[P/#Subaru outback]` both work.

**API:**

| function                                                                      | returns                                                                              |
| ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| `resolve(link, opts)`                                                         | all results `{ file, lnum, col, text, component, lines, doc }`, plus an error string |
| `resolve_first(link)`                                                         | the canonical result                                                                 |
| `resolve_node(link)`                                                          | the deepest section at the canonical result, plus the result                         |
| `process_link(parsed)`                                                        | UI wrapper that notifies when nothing matched                                        |
| `build_link(parts)`, `node_components(doc, node)`, `link_for_node(doc, node)` | link building                                                                        |
| `build_result_link(result)`                                                   | link shown in the quickfix list                                                      |
| `follow_targets(line)`, `follow_text(line, target)`                           | the links a `>` component can match on a line; the text it uses for one              |
| `search_lines`, `section_end`, `get_section_end`                              | building blocks                                                                      |

### Link index — `core/link_index.lua`

Every link span (`[...]`, `![...]`; from `doc:inline`) in every non-archived
note, with where it resolves. Persisted to `notes_dir/.z/link_index.json`
(through `core/state`; the version is bumped when extraction changes, which
forces a rebuild). The file is written 10 s after a refresh changed the
index and on exit, not on every refresh: encoding a large index is slow.

| function                                           | returns                                                                                      |
| -------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `links_from(file)`                                 | links found in a note, each `{ file, lnum, col, text, definition, target = { file, lnum } }` |
| `references(file, s, e)`                           | links whose target lies in lines `s..e` of `file`                                            |
| `backlinks(entity_or_{doc,node}, { descendants })` | links into an item's own content, or its whole subtree                                       |
| `unresolved()`                                     | links that resolve nowhere (`:ZortexBrokenLinks` puts them in quickfix)                      |
| `refresh(force)`, `rebuild()`                      | update now (normally lazy, at most once a second) / start over (`:ZortexLinkIndexRebuild`)   |

**Incremental refresh.** A note is re-read when its mtime/size changes (or, for
a modified buffer, its changedtick). A link is re-resolved only if:

- its own note changed,
- its current target's note changed,
- it was unresolved,
- its first component is not an article or tag (it searches every note), or
- its first component is an article or tag that a changed note declares.

If any changed note's header (aliases, tags) changed, every link is
re-resolved. Given how the resolver narrows candidates, no other link can
change target, so the cached results stay exact. Checkboxes (`[ ]`, `[x]`)
are not links.

### Entities — `core/entity.lua`

An _entity_ is a domain object that lives at a section and forms its own tree.
Projects, areas and objectives are entities.

`Entity` (the base class) provides:

- fields: `name`, `kind` (the section type), `file`, `lnum`, `start_line`,
  `end_line`, `depth`, `parent`, `children`
- identity: `path` (list of clean texts), `key` (`/`-joined path), `link`
- structure: `is_root`, `is_leaf`, `own_range` (header line → first child
  entity), `lines`, `walk`, `fold`, `ancestors`, `descendants`, `root`,
  `contains`, `breadcrumb`
- `backlinks({ descendants })` from the link index

`entity.registry(spec)` builds the lookup API for one kind:

```lua
entity.registry({
  kind = "project",
  namespace = "P",              -- link prefix: replaces an alias, or prefixes a tagged note's name
  class = Project,              -- Entity:extend() with domain methods
  init = function(e) ... end,   -- per-entity setup (attributes, ...)
  keep = function(node) return node.type == "heading" end,  -- articles are always kept
  sources = function() return { ...paths } end,
  is_source = function(doc) ... end,
  matches = function(e, opts) ... end,   -- optional extra all() filters
})
--> roots, all, get, at, current, resolve, lookup, jump, for_document, sources, is_source, signature
```

`signature()` changes whenever any source changes. Caches of derived data
(OKR link resolution, the calendar schedule index) key on it.

**Adding a new kind** (for example PARA _Resources_) is a spec plus a class:
choose the source notes, which section types count, and a namespace. See
`services/areas/` for the smallest complete example.

### Workspace — `core/workspace.lua`

A small editing layer (it replaced a 1,100-line stateful document manager).
Reads go through `core/document`; writes go through here:

- if the note is loaded in a buffer, the **buffer** is edited (unsaved, undo
  works, you save as usual)
- otherwise the **file** is edited directly

| function                                   | does                                                                                   |
| ------------------------------------------ | -------------------------------------------------------------------------------------- |
| `set_lines(target, s, e, lines)`           | replace lines `s..e` (`e = s - 1` inserts); target is a path or bufnr                  |
| `set_line`, `insert_lines`, `delete_lines` | shorthands                                                                             |
| `get_lines(target)`, `document(target)`    | current content / snapshot                                                             |
| `ensure_file(path, lines)`                 | create a note if missing                                                               |
| `get_doc_context()`                        | `{ bufnr, filepath, doc, section, lnum, col, line }` for the cursor in any note buffer |

Every edit emits `workspace:lines_changed` `{ file, start_line, end_line, count }`.

### State — `core/state.lua`

Everything Zortex keeps in `notes_dir/.z` is one JSON file per name, opened
with `State.open(name, { version, default })`:

| method                 | does                                                     |
| ---------------------- | -------------------------------------------------------- |
| `get()`                | the data table, loaded on first use                      |
| `save()`               | atomic write (temp file, then rename)                    |
| `reset()` / `reload()` | back to `default()` and save / forget the in-memory copy |

Loading never fails: a missing file gives `default()`, a corrupt one is kept
as `<name>.json.corrupt-<time>` and replaced, and a different version is
replaced by `default()`. Files: `link_index`, `search_history`, `xp_state`,
`notifications_state`; logs go to `.z/zortex.log`. Stores save when they
change; there is no persistence manager.

### Events and logging

`core/event_bus` carries a small set of domain events (the catalogue is at
the top of the file): `task:completed/uncompleted/created` (→ XP, digest),
`xp:awarded/removed`, `season:*`, `area:leveled_up`, `calendar:entry_*` (→ digest) and
`workspace:lines_changed` (→ digest live links). Handlers run asynchronously
in priority order; errors are reported, never raised into the emitter.

`core/logger` is a leveled logger (`trace` … `error`) with timers
(`start_timer(op)` returns a stop function). Entries go to a ring buffer
(`:ZortexLogs`) and, when `core.logger.enabled`, to `.z/zortex.log`;
`:ZortexPerformance` shows timer statistics.

## Domain layer

### Projects — `services/projects/`

| file            | role                                                                                                               |
| --------------- | ------------------------------------------------------------------------------------------------------------------ |
| `init.lua`      | Registry (sources: `projects.zortex` plus `@P` notes; namespace `P`). Also `query`, `tasks` and `update_progress`. |
| `project.lua`   | `Project` class: tasks, notes, stats, rollup, points, `is_done`, and relation methods.                             |
| `score.lua`     | Task and project scoring, indicators, and the comparators used by `query({ sort = … })`.                           |
| `relations.lua` | Schedule index (calendar), key results (OKR), areas.                                                               |

**Rules:**

- **Own content:** a project's own tasks run from its header line to its first
  sub-project. Container projects have their own tasks. Tasks are core/item
  Items with `project` set.
- **Points:** effort in estimated hours, from the configured sizes
  (`xp.sizes.task`: xs 0.25, sm 0.5, md 1, lg 2, xl 3, …). Unsized tasks
  count as `md`. An explicit project `@size` overrides the sum of its tasks
  with its hours (`xp.sizes.project`: lg = 20).
- **Links:** `[P/#1 Programming/#1.4 - zortex]` for the Projects article, and
  `[P/Flipping/#Subaru outback]` for a standalone note.

Full API: [Projects.md](Projects.md).

### Areas — `services/areas/`

The registry's source is `areas.zortex`. Headings, bold headings and labels
are areas, and the namespace is `A`.

- `Area` methods: `xp()` (own XP), `total_xp()` (including sub-areas),
  `xp_data()` (`{ xp, total_xp, level, progress }`), `projects({ descendants })`
  and `objectives({ descendants })`.
- Module helpers: `from_attributes(attrs)` and `resolve_links(attrs)` (for
  `@a(...)` values), `keys_for(...)` (XP area keys for tasks, projects and
  objectives; projects inherit areas from ancestors), `top(n)`, `get_area_tree()`.

### OKR — `services/okr/`

Objectives are entities (registry over `okr.zortex`, namespace `O`). Every
heading is an entity; headings matching `3M-2026-Q1 Title` are objectives
(`is_objective`), others such as
`# Current` are containers.

- **Objective:** `span`, `year`, `period`, `title`, `attributes`, `completed`
  (`@done`), `section` (parent heading), `key_results`, `progress()` (mean of
  its KRs), `areas()`, `projects()`, plus everything an entity has (`key`,
  `link` such as `[O/#Current/#3M-2026-Q1 Establish …]`, `backlinks()`, …).
- **Key result:** `- KR1: [ ] text …` lines directly under an objective;
  `kr.link` is the explicit link to the line (`[O/…/-KR1]`).
  `id`, `text`, `completed` (checkbox), `lnum`, `objective`, `projects`
  (`{ [project_key] = Project }`, from the link index, computed on access),
  `project_list()`, `progress()` and `is_done()`.
- **KR progress** = points done / points across the linked projects'
  subtrees. A checked KR is 1. A KR without project links is 0 until checked.
- API: `objectives({ current })`, `key_results({ open })`,
  `get_key_results(project)`, and the registry functions (`get`, `resolve`,
  `at`, …).

### Calendar — `stores/calendar.lua`

- The file is the source of truth. Date headings are top-level labels
  `YYYY-MM-DD:`; entries are the list items under them (`parse_lines`, each
  entry with its `lnum`), read from the current snapshot of `calendar.zortex`
  and re-parsed whenever the file or its buffer changes.
- **Edits are line edits** through `core/workspace`. `add_entry` inserts under
  the date's last entry (formatted like its siblings, `- ` for untimed
  entries) or creates the date heading in date order. `update_entry` replaces
  one line keeping its indentation. `delete_entry` (an entry from
  `get_entries_for_date`) removes one line. The
  header, notes, ordering and spacing are never rewritten.
- `projects/relations.schedule_index()` maps calendar links to projects through
  the link index; `project:schedule({ descendants, from, to })` reads it.

### Agenda — `services/agenda.lua`

One query over calendar entries, project tasks with `@due`, and projects with
`@due`. Items: `kind` (`event`/`task`/`note`/`due`/`project_due`), `date`,
`time`, `text`, `done`, `priority`, `entry` / `task` / `project`, `file`,
`lnum`. Within a day, timed items come first in time order, then by priority.

| function                                                  | returns                        |
| --------------------------------------------------------- | ------------------------------ |
| `day(date)`                                               | items for one day              |
| `range(from, to, { kinds, include_empty, include_done })` | `{ { date, items } }`          |
| `upcoming(days)`                                          | today and the following days   |
| `review({ days, today })`                                 | weekly review findings (below) |

`review()` returns `overdue`, `due_soon`, `completed` (by `@done` date),
`unscheduled` (open work, no calendar time ahead), `stale` (also none in the
last `days`), `no_next_action` (leaf projects without tasks),
`krs_without_projects`, `objectives_without_krs`, `areas_without_projects`
and `broken_links`. The calendar view's digest panel and `services/digest`
use the agenda.

### Digest — `services/digest.lua`

The daily digest note (`digest.zortex`, with live links), built from the
agenda and regenerated by `:ZortexDigestUpdate`. For email, `zortex serve`
has `GET /api/digest?days=7` (subject, text, html and the entries as JSON),
which a cron job can hand to any mail provider; Zortex doesn't send email
itself.

### Tasks — `services/tasks.lua`

`toggle_current_task` / `complete_current_task` / `uncomplete_current_task`
work in any note. Toggling edits the line in place: only the checkbox and
`@done(...)` change, so other attributes, tags and indentation stay as written. `find_task_by_id` searches project sources and the calendar.
After a toggle, `services/mirrors.sync` gives every other line with the
task's `@id` (project sources and calendar; not `[>]` lines) the same state,
and on a calendar line without a checkbox `toggle_reference` toggles the task
its link points at.

`services/mirrors` owns the shared-`@id` rules: `copies()` (the calendar's
tasks by `@id`, cached on the calendar snapshot), `apply(tasks)` (used by
`Project:tasks`, whose caches are dropped when the calendar snapshot changes:
a checked copy completes the task), `reference`, `ensure_id`, `issues`. The
ledger skips calendar copies of project tasks. `services/planner` puts copies
and project blocks on a day (`add_task`, `add_project`) and carries open
tasks forward (`carry`, pure, written to `tests/fixtures/carry.json` for
app/edit `Carry`).
Completing a task emits `task:completed` with the document context. Event
handlers run asynchronously (`vim.schedule`).

### XP — `services/xp/*` + `stores/xp.lua`

XP is derived, not recorded (see [Planning.md](Planning.md)):

- `xp/ledger` builds every award from the notes: project tasks (each
  project's pool paid out on the curve, live and archived tasks grouped by
  project key, dated by `@done`), other completed tasks (a cheap line scan of
  every note, not a full parse), key results reached, and objectives marked
  `@done`. Each award carries `aligned` (`"kr"`, `"area"` or nil). It is cached
  by the notes' mtimes / changedticks and rebuilt only when one changes.
- `xp/calculator` holds the formulas (task XP, project pool and curve,
  objective XP, area shares); it is pure.
- `xp/core` rebuilds after `task:completed/uncompleted` and saves of notes,
  once no key has been pressed for a second (a rebuild blocks input),
  compares with the last totals and emits `xp:awarded/removed`,
  `season:leveled_up`, `area:leveled_up`. It also stamps `@done(today)` on
  tasks checked by hand when a note is saved.
- `xp/publish` hands a summary to the web app after each refresh
  (`.z/xp_summary.json`, and `POST /api/xp` with a server), only when it
  changed.
- `stores/xp` keeps only seasons (name, date window, history), the level
  curves and the levels last announced.
- `xp/stats` (`require("zortex").xp`), the `XP*` and `Season*` actions, the
  mastery tree and `query.xp()` read the ledger. `Area:xp()` / `total_xp()`
  read it too (sub-areas count `xp.area.bubble` toward their parent).

## Entry points: API, actions, commands, keymaps

- **`require("zortex")`** (`init.lua` + `api.lua`) is `setup(opts)` plus the
  public API: every service by name, loaded on first use (`z.query`,
  `z.projects`, `z.areas`, `z.okr`, `z.agenda`, `z.calendar`, `z.tasks`,
  `z.search`, `z.links`, `z.link_index`, `z.document`, `z.syntax`, `z.item`,
  `z.notes`, `z.workspace`, `z.state`, `z.events`, `z.digest`, `z.review`,
  `z.xp`, `z.config`; the table is `api.SERVICES`), `z.actions.<id>()` and
  `z.run(id, args)`.
- **`actions.lua`** lists every user-facing action once: `id`, `command`,
  default `key`, `desc`, `group`, `run` (or `call(module, fn, ...)`, whose
  target `test_zr_actions` checks exists). `create_commands(prefix)` and
  `create_keymaps(prefix, mappings)` generate `:Zortex<Command>` and
  `<prefix><key>` from it, so a description is written once and a command can
  never point at a function that doesn't exist. `Config.keymaps.mappings`
  overrides keys by id (a key, a list, or `false`); `keymaps.enabled = false`
  skips them. `:ZortexHelp` and the README table (`tests/gen_docs.lua`,
  checked by a test) are generated from the same list.
- **`health.lua`**: `:checkhealth zortex` (notes dir, counts, broken links,
  state dir, optional integrations).

## UI layer

| module                                              | uses                                                      |
| --------------------------------------------------- | --------------------------------------------------------- |
| `ui/picker/init.lua` (+ a file per backend)         | telescope, snacks.picker, fzf-lua or `vim.ui.select`      |
| `ui/picker/projects.lua`                            | `projects.query`                                          |
| `ui/picker/search.lua`                              | `services/search` (picker only)                           |
| `ui/picker/follow.lua`, `calendar.lua`              | `features/links` (`>` links), `stores/calendar`           |
| `features/highlights.lua`, `folding.lua`, `toc.lua` | `core/document` syntax and tree                           |
| `ui/mastery_tree.lua`                               | `areas`, `projects`, `xp/stats`                           |
| `ui/calendar/view.lua` (+ `render`, `keys`)         | `stores/calendar`, `agenda` (digest panel), `projects`    |
| `features/completion.lua` (+ `blink.lua`)           | `core/link`, `notes`, `document`                          |
| `features/preview.lua`                              | `core/link`, `features/links`                             |
| `features/web.lua` (+ `core/tag_index.lua`)         | `core/link`, `notifications/server` (`/api/open`)         |
| `ui/review.lua`                                     | `agenda.review`                                           |
| `services/search_history.lua`                       | `services/search` (adds boosts); the picker records opens |

**Pickers** (`ui/picker`): each zortex picker is a spec (what to list, how
a row looks, where it points, a preview, extra keys), and a backend shows it:
`ui/picker/telescope`, `snacks`, `fzf_lua` or `select`, chosen by
`ui.picker` (`"auto"`: LazyVim's picker, else an enabled snacks.picker,
telescope, fzf-lua, snacks.picker, `vim.ui.select`). The spec gives either
`items` (a list the backend fuzzy-filters) or `query` (a live list re-run on
each keystroke, kept in its order: the structural search). Opening, several
rows to the quickfix list, previews and the spec's keys (`close`, `refresh`)
behave the same on every backend; `ui/picker/init.lua` has them. No backend
is required until a picker opens, so the plugin loads without any of them.

**Projects picker** (`ui/picker/projects.lua`): rows show
`ancestors › name  done/total  open-points  [P1,DUE]`.

- The preview shows attributes, own and total stats, areas, key results, the
  upcoming schedule, tasks sorted by score, and sub-projects.
- Keys: the picker's own to open, `<C-l>` inserts the link, `<C-y>` yanks it,
  `<M-s>` cycles the sort, `<M-d>` shows/hides done projects, `<M-e>` leaf-only.

**Highlighting** (`features/highlights.lua`) paints from the document's
syntax: each line kind and span type maps to a `Zortex*` group (headings,
labels, bullets with concealed markers, checkboxes, task text, KR keys,
objective ids, tables, quotes, code and math blocks, links with concealed
brackets, attributes, bold/italic with concealed markers, …). Only visual
decorations (operators, punctuation, quotes, percentages) are matched as
patterns, and never inside a span. **Folding** derives levels from the same
syntax (sections start folds; other lines nest by indentation), so code inside
fences never opens a fold.

**Structural search** (`services/search.lua` for matching and ranking,
`ui/picker/search.lua` for the picker; [Search.md](Search.md) is the user's
guide). Results are sections shown as **full breadcrumbs** of their
hierarchy, followed by lines that contain every word.

**Matching follows the path in order.** Search words are matched against a
section's path (article → headings → … → the section itself):

- earlier words match ancestors and the **last word matches the section
  itself**; consecutive words may match the same section
- `2 4` finds `1 › 2 › 3 › 4`, `2 › 4` and `2 › 3 › 4`, but not `4 › 2`, and
  not `2 › 4 › 5` (`4` is not the section itself)
- the best assignment of words to path parts is found exactly (a small dynamic
  program), not greedily
- the direct sub-sections of a match are listed under it

| word               | matches                                                   |
| ------------------ | --------------------------------------------------------- |
| `plain`            | any section (article aliases and the file name count, so `p` matches `@@P`) |
| `@@name`           | articles only                                             |
| `#name`            | headings only                                             |
| `:name`            | labels only                                               |
| `*name`            | bold headings only                                        |
| `@@`, `#`, … alone | any section of that type                                  |
| `a_b`, `a\ b`      | a word containing a space                                 |

**Ranking.** Each match is scored, and the picker keeps that order (a live
list: telescope's sorter returns each result's rank, snacks and fzf-lua leave
the order alone):

- score = 100 × word quality (per word: exact 3, prefix 2, substring 1)
  - type bonus (article 2000, heading 1000 − 50 × level, bold heading 400,
    label 300)
- **files are grouped**, best-scoring file first, live notes before archived
  ones (shown with `(archive)`)
- inside a file, results stay in **document order**, so parents sit above
  their children

So typing `p` lists the Projects file first (exact alias match on its
article), with its sections in order, then the next best file.

**Settings** (`setup(opts)` deep-merges `opts` over `Config.defaults.ui.search`;
calling `search.setup()` with no arguments resets to the defaults):

| option               | effect                                                                                                                                                                                 |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `default_mode`       | `"section"`: sections, then lines. `"article"`: article names only. `<M-t>` toggles in the picker.                                                                                     |
| `max_results`        | caps the results of each query                                                                                                                                                         |
| `token_filters[n]`   | section types that may be a result when the prompt has `n` words (the last entry applies beyond). Bold headings and labels above the first heading count as H1. Typed words bypass it. |
| `access_decay_rate`  | per-day decay of a note's "opened from search" score (see history below)                                                                                                               |
| `history`            | `{ enabled, max_entries, score_decay, propagation_decay }`: per-section history                                                                                                        |
| `breadcrumb_display` | reserved; nothing reads it yet (results always show the full breadcrumb)                                                                                                               |

**Search history** (`services/search_history.lua`, stored in
`notes_dir/.z/search_history.json`). Opening a result (or sending it to the
quickfix list) records it:

- the note's score gets +1, decaying by `access_decay_rate` per day
- the section and its ancestors get +1, ×`propagation_decay` per level,
  decaying by `history.score_decay`; sections are keyed by note +
  breadcrumb, so the history survives edits that move lines; only the
  `max_entries` strongest are kept
- scores are stored as `(value, time)` and decayed on read:
  `value · exp(−rate · days)`
- a match's score gains `50·ln(1 + note score) + 30·ln(1 + section score)`.
  Word quality is worth 100 per point, so history reorders similar matches
  and files but never outranks a better match type (article vs heading)
- `search_history.clear()` forgets everything

**Completion** (`features/completion.lua`; the nvim-cmp source, and
`features/blink.lua` for blink.cmp, both from `lsp_items`): `setup()`
registers it on the first zortex buffer, with blink.cmp when it is installed
(the `zortex` provider, listed for zortex buffers) and nvim-cmp otherwise
(the zortex buffers' sources). The
components already typed are resolved with the link resolver, and the
suggestions are what can come next. After `[` that's article names and aliases
(`[@` gives tags). After an article, its sections; when the article was
reached through a tag (`[P/` reaching an `@P` note), the note's own name.
After a section, its sub-sections, children first. `#`, `:` and `*` narrow to
headings, labels and bold headings. Every suggestion resolves.
`get_completions(line, col, opts)` is the testable core.

**Hover preview:** with `ui.preview.on_hover = true`, resting the cursor on a
link (`CursorHold`; `'updatetime'` is the delay) previews it without taking
focus; moving away closes it.

**Link preview** (`features/preview.lua`, `:ZortexLinkPreview`,
`<prefix>K`): a floating window with the section the link under the cursor
resolves to, Zortex-highlighted, focused on the matched line. `<CR>` opens the
target, `q`/`<Esc>` close, moving the cursor closes it, and calling it again
focuses it. Footnotes preview their definition.

**Day planner** (`ui/planner.lua` + `services/planner.lua`, `:ZortexPlan
[date]`, `<prefix>m`): opens `calendar.zortex` at the day, creating it from
`ui.planner.templates` (`monday` … `sunday` override `weekday` / `saturday` /
`sunday`), and a `zortex://plan` window beside it with ranked candidates:

- **Tasks** score by adding signals (`planner.weights`): in the TODO project
  (`ui.planner.todo_link`, default `P/#TODOs`) 3, `@p1/2/3` 3/2/1, `@i1/2`
  2/1, overdue 4, due today 3, within 3 days 2, within a week 1, project
  linked from an open KR 2; overdue calendar tasks are included.
- **Projects** that are OKR-linked or high priority/importance, **key
  results** of current objectives (least progress first) and **areas** (two
  levels, fewest active projects first).
- Every line is exactly what gets written: plain text plus one explicit link
  to the item; badges (`TODO · P1 · due 10-12 · OKR`) are virtual text.
- Keys: `i`/`o`/`O` put the text on the current / next / previous calendar
  line (no marker) and jump there in insert mode at the line start to type a
  time; `p` adds `- text` after the day's last entry and keeps focus in the
  plan (`calendar.date_block`); `<CR>` puts at the calendar cursor
  (`planner.put`: single spaces, never inside a `09:00` or `- ` marker);
  `<C-n>`/`<C-p>` move the calendar cursor, `<Tab>` to the calendar,
  `gx`/`K`, `r`, `q`. `query.plan()` returns the same candidates.

**Projects sorting** adds OKR alignment: projects linked from open key results
(directly or through an ancestor) get `score.weights.okr` (80, +20 per extra
KR, max 140) in `project_score`, an `OKR` indicator, and come first within a
priority in the `priority` sort; the picker also has an `okr` sort.

**Weekly review** (`ui/review.lua`, `:ZortexReview [days]`, default 7):
`agenda.review()` rendered into a read-only, Zortex-highlighted scratch
buffer `zortex://review`. Sections: Tasks (overdue, due soon, completed),
Projects (stale, unscheduled, no next action, with done/total and open
points), Goals (KRs without projects, objectives without KRs, areas without
active projects) and Notes (broken links). Each line carries the link of its
project/objective/area, so `gx` and `K` work; `<CR>` jumps to the source
line, `r` refreshes, `q` closes. `render(review)` is pure (lines plus a
line → location map) so other front ends can reuse the layout.

**Query API** (`query.lua`): the model as plain data — `tree(dir)` (folders
and notes with titles, tags, archived flag, mtime), `note(path)` (header,
outline, lines and full syntax with spans), `search(prompt)`,
`resolve(link)`, `backlinks(path, lnum)`, `broken_links()`, `projects()`,
`areas()`, `objectives()`, `agenda(from, to)`, `review(opts)`, and
`export(dir)` (`:ZortexExport [dir]`, default `notes_dir/.z/export`:
`index.json` plus `notes/<rel>.json`). Dates are `YYYY-MM-DD` strings; every
result survives `vim.json.encode`.

**Mastery tree** (`ui/mastery_tree.lua`): season status from `xp/stats`, top areas
from `areas.top`, and the area tree from Area objects. Levels come from
`total_xp`. The highlight groups `ZortexMasteryLevel1..4` and `ZortexProgressBar`
default-link to standard groups.

**Calendar view** (`ui/calendar/`): `view.lua` owns the window and its
state (`view.state`: selected date, view mode, day cells), `render.lua`
turns that into lines and highlights (`month`, `digest`), and `keys.lua`
moves the selection and runs actions (`attach` maps `Config.ui.calendar.keymaps`).
Cell positions in `state.marks` are **display columns**. Anything that needs byte
columns (extmarks) must convert them with `render.display_col_to_byte`, because wide
icons take two columns but one character.

## Configuration

`Config.setup(opts)` deep-merges `opts` into the defaults in `config.lua`.
`Config.defaults` exposes those defaults read-only, so a module can overlay
its own slice the same way `search.setup` does. Relevant constants live in
`constants.lua`:

| constant                   | meaning                             |
| -------------------------- | ----------------------------------- |
| `PROJECT_TAG = "P"`        | the projects tag and link namespace |
| `ARCHIVE_TAG = "Archive"`  | marks archived notes                |
| `DEFAULT_TASK_SIZE = "md"` | what an unsized task counts as      |

## Testing

```sh
nvim --headless -u NONE -l tests/run.lua            # everything
nvim --headless -u NONE -l tests/run.lua projects   # files whose name contains "projects"
nvim --headless -u NONE -l tests/gen_ast.lua        # regenerate the AST fixtures (after a grammar change)
nvim --headless -u NONE -l tests/gen_links.lua      # regenerate the resolve/search fixtures (after a resolver or search change)
go -C app test ./...                                # Go parser, resolver, search, web app, notifications, pomodoro

# the pickers and completion against the real plugins (pinned; also in CI)
tests/plugins.sh .tests/plugins
ZORTEX_TEST_PLUGINS=$PWD/.tests/plugins nvim --headless -u NONE -l tests/run.lua
```

**One grammar, two implementations.** `core/syntax.lua` is the
specification. `tests/gen_ast.lua` writes its output for every
`tests/fixtures/{notes,syntax}/*.zortex` to `tests/fixtures/ast/`; the Lua
suite (`test_syntax`) and the Go port (`app/syntax`, `TestConformance`)
both compare against those files, so a change to the grammar is made in Lua,
the fixtures are regenerated, and the Go port is fixed until it agrees again.
`syntax/edge.zortex` collects corner cases and `syntax/random.zortex` is 600
lines of shuffled syntax fragments.

The link resolver and structural search work the same way: `tests/gen_links.lua`
runs them over the fixture notes and writes `tests/fixtures/resolve.json`
(every section's canonical link, every link written in the notes and
hand-picked cases: aliases, tags, archives, local links, failures, with their
targets or error text) and `tests/fixtures/search.json` (31 prompts with the
ranked results, scores and breadcrumbs). `test_links` checks the files are up
to date; `app/links` and `app/search` must reproduce them.

- `tests/run.lua` has no plugin dependencies (`ZORTEX_TEST_PLUGINS` adds
  them for `test_zzz_integrations`; `ZORTEX_TEST_ONLY=text` runs only tests
  whose name contains it). It copies
  `tests/fixtures/notes` to a temp directory (stores write state files into
  `notes_dir`) and points `Config.notes_dir` at it.
- The fixtures are built from real examples: a Projects article, a standalone
  `@P` note, a nested `@P` note in `z/`, an archived copy, OKR, areas and the
  calendar.

| test file                | covers                                                                                                                                                                           |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `test_core`              | header, levels, tree, notes index                                                                                                                                                |
| `test_syntax`            | line kinds, items, inline spans, link lookups, Items for tasks/KRs/calendar, AST conformance fixtures, highlights, folds, the grammar loading with only the Lua standard library |
| `test_links`             | resolution rules, canonical results, archive handling, `[@P/…]`, round-trips                                                                                                     |
| `test_projects`          | registry, stats/points, `P/` links, schedule, KRs, areas                                                                                                                         |
| `test_areas`             | area tree, `A/` links, projects/objectives, XP keys                                                                                                                              |
| `test_search`            | config overlay, token filters, typed tokens, modes                                                                                                                               |
| `test_tasks`             | toggling in a standalone note without losing unsaved edits; XP context                                                                                                           |
| `test_load`              | every module under `lua/zortex` loads without the optional plugins                                                                                                               |
| `test_okr`               | objective entities, `O/` links, KR projects and progress                                                                                                                         |
| `test_agenda`            | day/range items, due tasks, review findings                                                                                                                                      |
| `test_completion`        | link context, suggestions per position, every suggestion resolves                                                                                                                |
| `test_zq_planner`        | put rules, templates, candidate ranking and links, putting into the calendar                                                                                                     |
| `test_zr_actions`        | every action complete, targets exist, commands/keymaps/overrides, API, backlinks, README table up to date                                                                        |
| `test_zs_query`          | every query function returns JSON-safe data; export                                                                                                                              |
| `test_zt_state`          | state files: defaults, versions, migration, corrupt files                                                                                                                        |
| `test_zu_review`         | review buffer layout, links, jumps                                                                                                                                               |
| `test_zv_search_history` | recording, decay, persistence, boosts                                                                                                                                            |
| `test_zw_archive`        | archiving merges under existing ancestors                                                                                                                                        |
| `test_zw_edits`          | editing layer; calendar line edits keep the file intact; buffer vs file                                                                                                          |
| `test_zx_link_index`     | backlinks, unresolved links, incremental refresh, reload from disk                                                                                                               |
| `test_zy_preview`        | preview content, focus line, `<CR>` opens the target                                                                                                                             |
| `test_picker`            | backend choice, confirm / quickfix, the search spec, blink.cmp and nvim-cmp registration (stub plugins)                                                                          |
| `test_zz_setup`          | full `require("zortex").setup()`, then opening and navigating the calendar                                                                                                       |
| `test_zzz_integrations`  | with `ZORTEX_TEST_PLUGINS` (`tests/plugins.sh`): every picker key on telescope, snacks and fzf-lua; the blink.cmp provider                                                       |

## Conventions

- **Never compare links as text.** Resolve them (`core/link`,
  `projects.resolve`, `areas.resolve`) and compare keys.
- **Read notes through `core/document`.** That gives one parse, consistent
  structure, and live buffer contents.
- **Ask `core/syntax` what a line is.** Don't match line patterns in feature
  code; extend the grammar (and regenerate the fixtures) instead.
- **List items are Items.** Tasks, entries and key results share `core/item`.
- **State goes through `core/state`.**
- **Domain objects are entities.** Put shared behaviour in `core/entity`, and
  only domain behaviour in the subclass.
- **Keep the UI thin.** Pickers and views format API results; they don't
  parse notes.
