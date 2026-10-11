# Zortex architecture

How the Lua side of zortex.nvim is put together: what each layer is for, how
data moves from a `.zortex` file to a project in a picker, and the rules every
module agrees on. For the projects/areas API reference see
[Projects.md](Projects.md). For what changed on the `projects-api` branch, see
[Changes.md](Changes.md).

## Summary

Every note is parsed **once** into a cached *document*. A document holds the
lines, a structural tree, and the header (article names and tags). Everything
else is built on documents:

- **Links** resolve against documents with one resolver. A link means the same
  thing when you follow it, when completion suggests it, and when projects,
  OKRs or the calendar look it up.
- **Projects** and **areas** are *entities*: objects derived from sections of
  the tree, each with a stable key (its tree path) and a canonical link.
- **Relations** connect them: calendar entries, key results and area links are
  resolved to entity keys, never compared as link text.
- **UI** (pickers, skill tree, calendar, digest) only reads these APIs.

```
            ┌───────────────────────────────────────────────────────────┐
  UI        │ telescope/projects  telescope/search  skill_tree  calendar │
            │ commands  keymaps  digest                                  │
            └──────────────▲────────────────────────────▲────────────────┘
                           │                            │
            ┌──────────────┴──────────┐   ┌─────────────┴──────────────┐
  Domain    │ services/projects       │   │ services/xp (core, stats,  │
            │ services/areas          │◄──┤  calculator) + stores/xp   │
            │ services/okr  tasks     │   └────────────────────────────┘
            │ projects/relations      │
            └──────────────▲──────────┘
                           │  entity.registry(spec)
            ┌──────────────┴──────────────────────────────────────────┐
  Core      │ core/entity   utils/link_resolver   core/notes          │
            │ core/document ──► core/section (tree)                   │
            │ utils/parser (levels, header, sections, links, tasks)   │
            └─────────────────────────────────────────────────────────┘
```

## Notes on disk

| Thing | Syntax | Meaning |
|---|---|---|
| Article names | `@@Projects`, `@@P` | Header lines. The first is the primary name; the rest are aliases. |
| Tags | `@P`, `@Cars`, `@Archive` | Header lines starting with a single `@`. |
| Header | leading `@@`/`@` lines | Blank lines are skipped; the header ends at the first other line. |
| Heading | `# …` to `###### …` | Levels 1 to 6. |
| Bold heading | `**Text**` or `**Text**:` | Level 7. |
| Label | `Text:` (no `. ` inside) | Level 8 + indent, so indented labels nest. |
| Task | `- [ ] text`, `- [x] text` | Attributes come from the task text. |
| Attribute | `@key(value)`, `@p1`, `@2h` | Parsed with a schema (`utils/attributes`). |

**Special notes:**
- `projects.zortex` is the Projects article (`@@Projects` / `@@P`).
- Any note tagged `@P` is a standalone project.
- `areas.zortex` is the Areas article (`@@Areas` / `@@A`).
- `okr.zortex` holds objectives and key results.
- `calendar.zortex` is the schedule.
- Notes named `z/archive.*.zortex`, or tagged `@Archive`, are archived and
  ignored by link resolution and project lists.

## Core layer

### One structural level scale — `constants.SECTION_HIERARCHY`

| Section | Level |
|---|---|
| article | 0 |
| heading | 1–6 (`#` count) |
| bold heading | 7 |
| label | 8 + indent |
| tag / text | not structural |

A section ends at the next section with a level **≤** its own. The tree builder,
`parser.find_section_end`, breadcrumbs, section navigation and archive merging
all use this one scale. Before this branch there were two scales (0–8 and
10–100), and some modules compared numbers from both.

### Parser — `utils/parser.lua`

These are the single sources of truth:

- `parse_header(lines)` → `{ names, tags, tag_lines, name_lnum, last_lnum }`.
  This is the only header parser; workspace, documents, notes, completion and
  archive all use it.
- `calculate_level(line)` and `section_text(line, type)`. Section text has
  attributes stripped: `## 1.4 - zortex @p1 @size(lg)` → `1.4 - zortex`.
- `strip_attributes(text)` only removes `@` tokens that start a word, so
  `me@example.com` survives.
- `scan_sections(lines)` makes one pass and returns flat descriptors. The
  header produces **one** article descriptor carrying all its `names`.
- `build_section_path(lines, lnum)` and `find_section_end(...)` give
  lines-only answers that agree with the tree.
- `parse_link_definition` / `parse_link_component` / `split_query` parse links.
  A typed component (`#…`, `:…`, `-…`, `*…`) is never split as a `+` / `&`
  query, so `#4 Learning & Education` is a heading.
- `parse_task(line)` parses tasks.

### Sections — `core/section.lua`

`build_tree(lines)` assembles a `Section` tree under a synthetic `root`. Nodes
have `type`, `text` (clean), `level`, `start_line`, `end_line`, `children`,
`parent`, and `names` (article nodes only).

**Generic helpers**, used by search and by entities:

| helper | does |
|---|---|
| `walk(fn)` | pre-order; return `false` to skip children |
| `find(pred)` / `filter(pred)` | first / all matches |
| `fold(fn)` | post-order aggregation `fn(node, child_results)` |
| `ancestors()`, `path_texts()`, `get_breadcrumb(sep)`, `depth()` | paths |
| `get_direct_end_line()`, `get_direct_lines(bufnr)` | content before the first child |
| `derive(root, keep, make)` | builds a domain tree from chosen node types (see entities) |

### Documents — `core/document.lua`

A `Document` is an immutable snapshot `{ filepath, lines, tree, names, tags, header }`.

- `Document.from_file(path)` is cached by mtime (seconds + nanoseconds) and size.
- `Document.from_buffer(bufnr)` is cached by `changedtick`.
- `Document.get(path)` **prefers a loaded, modified buffer** over the file, so
  unsaved edits are visible everywhere (project stats, links, OKR).
- `Document.resolve(x)` accepts a Document, a path or a bufnr.
- Methods: `name()`, `has_name()`, `has_tag()`, `article()`, `node_at(lnum)`,
  `node_starting_at(lnum)`, `get_lines()`.

Because snapshots are immutable, anything derived from one (projects, areas)
is cached **on the snapshot**. When the file changes there is a new snapshot,
and the cache goes with the old one.

`core/tree.lua` is now a thin facade (`get_tree(path)` → `Document.get(path).tree`)
used by structural search. The old JSON tree cache in `stdpath("cache")` is gone.

### Notes index — `core/notes.lua`

- `files()` lists every note recursively, top-level first then alphabetically,
  without archived notes.
- `index()` is a short-lived (1 s) snapshot `{ files, headers }`, so bulk
  work (resolving many links) doesn't re-stat every file per link.
- `find_by_name(name)` and `find_by_tag(tag)` are case-insensitive.
- `header(path)` reads **only** the header block, cached by mtime.
- `is_archived(path)` is true for `archive.*` filenames or the `@Archive` tag.

### Links — `utils/link_resolver.lua`

A link is `/`-separated components resolved **left to right**. Each component
narrows a list of candidates (file + line range):

| Component | Example | Narrows to |
|---|---|---|
| Article | `P`, `Projects` | Files declaring the alias, **then** files tagged with it. |
| Tag | `@P` | Files whose header has the tag. If no file declares it, a line search for `@P`. |
| Heading | `#1.4 - zortex` | Heading lines whose text **starts with** the text, case-insensitive, at **any depth** in the current range. |
| Label / bold / list item | `:Fitness`, `*X`, `-item` | Line searches. |
| Query | `%text`, `a + b`, `a & b` | Line searches. Case-sensitive only if the query has an uppercase letter. |

**Rules for the result:**
- For a non-final component, the **first match in each file** becomes the new
  range: the section starting at that line (`doc:node_starting_at`), or
  `find_section_end` as a fallback.
- Results come back in note order (top-level files first, then line order), and
  `results[1]` is the **canonical** target. So `[P/#1.4]` resolves to the first
  `1.4…` heading, which is the parent of any children sharing that prefix.
- Archived notes are skipped unless a component is `@Archive` or
  `opts.include_archived` is set.
- Local links (`[/…]`) resolve in the current buffer.

The article-or-tag rule is what lets `[P/…]` mean "the project namespace". It
searches the Projects article first, then every `@P` note, so
`[P/Flipping/#Subaru outback]` and `[P/#Subaru outback]` both work.

**API:**

| function | returns |
|---|---|
| `resolve(link, opts)` | all results `{ file, lnum, col, text, component, lines, doc }`, plus an error string |
| `resolve_first(link)` | the canonical result |
| `resolve_node(link)` | the deepest section at the canonical result, plus the result |
| `process_link(parsed)` | UI wrapper that notifies when nothing matched |
| `build_link(parts)`, `node_components(doc, node)`, `link_for_node(doc, node)` | link building |
| `build_result_link(result)` | link shown in the quickfix list |
| `search_lines`, `section_end`, `get_section_end` | building blocks |

### Entities — `core/entity.lua`

An *entity* is a domain object that lives at a section and forms its own tree.
Projects and areas are entities.

`Entity` (the base class) provides:
- fields: `name`, `kind` (the section type), `file`, `lnum`, `start_line`,
  `end_line`, `depth`, `parent`, `children`
- identity: `path` (list of clean texts), `key` (`/`-joined path), `link`
- structure: `is_root`, `is_leaf`, `own_range` (header line → first child
  entity), `lines`, `walk`, `fold`, `ancestors`, `descendants`, `root`,
  `contains`, `breadcrumb`

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

**Adding a new kind** (for example PARA *Resources*) is a spec plus a class:
choose the source notes, which section types count, and a namespace. See
`services/areas/` for the smallest complete example.

### Workspace — `core/workspace.lua`

This is the stateful editing layer behind task toggling. It is unchanged in
design apart from three things:

- It reads headers with `parser.parse_header` and exposes `doc.tags`.
- It finds core documents by comparing resolved full paths, not just file names.
- `get_doc_context()` also works in **any** note buffer through
  `get_note_for_buffer`. That document is seeded from the buffer (so unsaved
  edits are never overwritten), is never saved by the workspace, and is
  dropped when the buffer unloads.

## Domain layer

### Projects — `services/projects/`

| file | role |
|---|---|
| `init.lua` | Registry (sources: `projects.zortex` plus `@P` notes; namespace `P`). Also `query`, `tasks` and `update_progress`. |
| `project.lua` | `Project` class: tasks, notes, stats, rollup, points, `is_done`, and relation methods. |
| `score.lua` | Task and project scoring, indicators, and the comparators used by `query({ sort = … })`. |
| `relations.lua` | Schedule index (calendar), key results (OKR), areas. |

**Rules:**
- **Own content:** a project's own tasks run from its header line to its first
  sub-project. Container projects have their own tasks.
- **Points:** `@size(xs…xl)` maps to 1, 2, 3, 5, 8, and project-only sizes go
  up to `ultimate` = 55 (`constants.SIZE_POINTS`). Unsized tasks count as `md`.
  An explicit project `@size` overrides the sum of its tasks.
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

### OKR — `services/okr.lua`

- **Objectives** are headings whose clean text matches `3M-2026-Q1 Title`, or
  the legacy `3M 2026 01 Title`.
- **Key results** are `- KR1: [ ] text …` lines directly under an objective.
- Each KR's links are resolved to **projects by key** (`kr.projects[key]`).
- Results are cached per (okr document, projects signature).
- API: `get_objectives()`, `get_current_objectives()`,
  `get_key_results(project_or_key_or_link)`, `parse_objective`, `parse_key_result`.

### Calendar

- `stores/calendar.parse_lines(lines)` is the one parser for `calendar.zortex`.
  It returns `{ ["YYYY-MM-DD"] = { CalendarEntry… } }`, and each entry carries
  `lnum`. The store's `load()` and the schedule index both use it.
- `projects/relations.schedule_index()` resolves every link in every entry to a
  project key. `project:schedule({ descendants, from, to })` reads from it.

### Tasks — `services/tasks.lua`

`toggle_current_task` / `complete_current_task` / `uncomplete_current_task`
work in any note. `find_task_by_id` searches project sources and the calendar.
Completing a task emits `task:completed` with the document context. Event
handlers run asynchronously (`vim.schedule`).

### XP — `services/xp/*` + `stores/xp.lua`

**When a task changes:**

1. `xp/core.build_xp_context`:
   - finds the project with `projects.at(bufnr, lnum)`
   - finds its key results with `okr.get_key_results(project)`
   - finds area keys with `areas.keys_for(task, project, objectives…)`
2. `xp/calculator` computes the XP amount and its distribution (season and areas).
3. `stores/xp` records the transaction. Transaction ids are project keys, and
   area XP is stored under **area keys**.

**Reading and display:**
- `xp/stats` gives season status, per-project XP, area stats, season
  start/end, and the stats and area-ranking displays.
- `api.xp.*`, the `XP*` and `Season*` commands, and the skill tree all use
  `xp/stats`.

**Config read by `stores/xp`:** `xp.season.level_curve`, `xp.season.tiers`
and `xp.area.level_curve`. The older `xp.project.season_curve` key is still
accepted.

## UI layer

| module | uses |
|---|---|
| `ui/telescope/projects.lua` | `projects.query` |
| `ui/telescope/search.lua` | `core/tree` and `Config.ui.search` (via `setup`) |
| `ui/skill_tree.lua` | `areas`, `projects`, `xp/stats` |
| `ui/calendar/view.lua` | `stores/calendar`, `projects` |
| `ui/calendar/init.lua` | `stores/calendar` |
| `services/digest.lua` | `projects.query`, `projects.tasks`, `link_resolver` |

**Projects picker** (`ui/telescope/projects.lua`): rows show
`ancestors › name  done/total  open-points  [P1,DUE]`.

- The preview shows attributes, own and total stats, areas, key results, the
  upcoming schedule, tasks sorted by score, and sub-projects.
- Keys: `<CR>`/`<C-x>`/`<C-v>` open, `<C-l>` inserts the link, `<C-y>` yanks it,
  `<C-s>` cycles the sort, `<C-d>` shows/hides done projects, `<C-e>` leaf-only.

**Structural search** (`ui/telescope/search.lua`) works like the original
search service. Results are sections shown as **full breadcrumbs** of their
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

| word | matches |
|---|---|
| `plain` | any section (article aliases count, so `p` matches `@@P`) |
| `@@name` | articles only |
| `#name` | headings only |
| `:name` | labels only |
| `*name` | bold headings only |
| `@@`, `#`, … alone | any section of that type |
| `a_b`, `a\ b` | a word containing a space |

**Ranking.** Each match is scored, and the picker keeps that order (its sorter
returns each result's rank and only borrows the fuzzy sorter's highlighter):

- score = 100 × word quality (per word: exact 3, prefix 2, substring 1)
  + type bonus (article 2000, heading 1000 − 50 × level, bold heading 400,
  label 300)
- **files are grouped**, best-scoring file first, live notes before archived
  ones (shown with `(archive)`)
- inside a file, results stay in **document order**, so parents sit above
  their children

So typing `p` lists the Projects file first (exact alias match on its
article), with its sections in order, then the next best file.

**Settings** (`setup(opts)` deep-merges `opts` over `Config.defaults.ui.search`;
calling `search.setup()` with no arguments resets to the defaults):

| option | effect |
|---|---|
| `default_mode` | `"section"`: sections, then lines. `"article"`: article names only. `<C-t>` toggles in the picker. |
| `max_results` | caps the results of each query |
| `token_filters[n]` | section types that may be a result when the prompt has `n` words (the last entry applies beyond). Bold headings and labels above the first heading count as H1. Typed words bypass it. |
| `breadcrumb_display`, `min_score`, `access_decay_rate`, `history` | reserved; nothing reads them yet (results always show the full breadcrumb) |

Telescope is loaded lazily, so the plugin sets up without it. [Search.md](Search.md)
is the fuller target spec; the table above is what is implemented.

**Skill tree** (`ui/skill_tree.lua`): season status from `xp/stats`, top areas
from `areas.top`, and the area tree from Area objects. Levels come from
`total_xp`. The highlight groups `ZortexSkillLevel1..4` and `ZortexProgressBar`
default-link to standard groups.

**Calendar view** (`ui/calendar/view.lua`): cell positions in
`CalendarState.marks` are **display columns**. Anything that needs byte
columns (extmarks) must convert them with `display_col_to_byte`, because wide
icons take two columns but one character.

## Configuration

`Config.setup(opts)` deep-merges `opts` into the defaults in `config.lua`.
`Config.defaults` exposes those defaults read-only, so a module can overlay
its own slice the same way `search.setup` does. Relevant constants live in
`constants.lua`:

| constant | meaning |
|---|---|
| `PROJECT_TAG = "P"` | the projects tag and link namespace |
| `ARCHIVE_TAG = "Archive"` | marks archived notes |
| `SIZE_POINTS`, `DEFAULT_TASK_SIZE` | task and project sizing |
| `PATTERNS.OBJECTIVE`, `PATTERNS.KEY_RESULT` | OKR formats |

## Testing

```sh
nvim --headless -u NONE -l tests/run.lua            # everything
nvim --headless -u NONE -l tests/run.lua projects   # files whose name contains "projects"
```

- `tests/run.lua` has no plugin dependencies. It copies
  `tests/fixtures/notes` to a temp directory (stores write state files into
  `notes_dir`) and points `Config.notes_dir` at it.
- The fixtures are built from real examples: a Projects article, a standalone
  `@P` note, a nested `@P` note in `z/`, an archived copy, OKR, areas and the
  calendar.

| test file | covers |
|---|---|
| `test_core` | header, levels, tree, section ends, notes index |
| `test_links` | resolution rules, canonical results, archive handling, `[@P/…]`, round-trips |
| `test_projects` | registry, stats/points, `P/` links, schedule, KRs, areas |
| `test_areas` | area tree, `A/` links, projects/objectives, XP keys |
| `test_search` | config overlay, token filters, typed tokens, modes |
| `test_tasks` | toggling in a standalone note without losing unsaved edits; XP context |
| `test_load` | every module under `lua/zortex` loads (Telescope stubbed) |
| `test_zz_setup` | full `require("zortex").setup()`, then opening and navigating the calendar |

## Conventions

- **Never compare links as text.** Resolve them (`link_resolver`,
  `projects.resolve`, `areas.resolve`) and compare keys.
- **Read notes through `core/document`.** That gives one parse, consistent
  structure, and live buffer contents.
- **Domain objects are entities.** Put shared behaviour in `core/entity`, and
  only domain behaviour in the subclass.
- **Keep the UI thin.** Pickers and views format API results; they don't
  parse notes.
