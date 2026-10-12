# Changes on `projects-api`

Everything this branch changed relative to `28a3ce2`, grouped by area, with
the behaviour changes you might notice and what to do about them. For how the
result fits together, see [Architecture.md](Architecture.md).

## Overview

The branch started from a broken projects search and ended with these pieces
in place:

1. **A shared core:** one level scale, one header parser, cached documents, a
   notes index, and generic tree helpers.
2. **One link resolver.** It keeps the existing "follow a link" rules, runs on
   documents, and adds `[@P/…]` and the `P/` namespace.
3. **Projects, areas and objectives as entities** on a common base
   (`core/entity`), with relations to the calendar, OKRs and areas resolved
   by key; KR progress computed from linked projects.
4. **A persistent link index** (`.z/link_index.json`) with backlinks and
   broken-link reports, refreshed incrementally.
5. **One agenda query** for the calendar view, digest note and email digest,
   plus a `review()` API for weekly reviews.
6. **Safe editing:** a small editing layer replaces the old workspace; the
   calendar and task toggling edit single lines instead of rewriting.
7. **Completion and link preview** built on the resolver.
8. **Fixes:** every module now loads, `setup()` completes, the calendar opens,
   and the XP pipeline works end to end.
9. **A weekly review buffer** (`:ZortexReview`) and **search history** that
   ranks recently and frequently opened notes and sections higher.
10. **One parser and one item type:** `core/syntax` is the whole Zortex
    grammar (lines and inline spans, plain Lua, conformance fixtures);
    highlighting, folding, tasks, calendar, OKR, link extraction and search
    all read it. Tasks, calendar entries and key results share `core/item`.
11. **One way to keep state** (`core/state` for every `.z` file) and a
    **plain-data API** (`zortex.query`, `:ZortexExport`) for anything outside
    Neovim.
12. **Actions as data:** commands, keymaps, `:ZortexHelp` and the README table come from one list (`actions.lua`); `require("zortex")` exposes every service.
13. **A headless test suite:** 211 Lua tests plus the server's Python tests, no dependencies.
14. **A Go port** of the grammar, notes index, link resolver and search
    (`app/`), held to the Lua behaviour by generated fixtures.

## Commits

| commit | summary |
|---|---|
| Make projects first-class | Shared core, one link resolver, projects API, OKR rewrite, picker rebuilt, first round of fixes. |
| Areas as first-class objects | `core/entity` base, `P/` project links, areas API, XP keyed by area, stale `services.xp` / `services.calendar` callers fixed, task toggling in any note. |
| Search setup, calendar crash, docs | `search.setup()` with config overlay and implemented options, calendar selection crash, these docs. |
| Hierarchy-first search ranking | The picker keeps the search's own order instead of re-sorting by fuzzy score; the synthetic root is no longer matchable. |
| Restore ordered path search | Words match a section's path in order (last word = the section), with the original scoring, file grouping, document order, direct sub-sections and full breadcrumbs. |
| Link index, agenda, OKR entities, editing layer | Persistent link index with backlinks; agenda + review API used by all digests; objectives as entities with KR progress; workspace replaced by an editing layer; calendar and task edits as line edits; completion and link preview on the resolver; several existing bugs fixed. |
| Weekly review buffer, search history | `:ZortexReview [days]` renders `agenda.review()`; search records opened results in `.z/search_history.json` with decay and boosts matches. |
| Universal parser and shared item type | `core/syntax` and `core/item`; documents carry the syntax; highlights, folding, TOC, archive, link index, resolver, projects, OKR, calendar and tasks moved onto it; AST conformance fixtures. |
| One state module; smaller logger | `core/state` for `.z` files; persistence manager and base store removed; logger rewritten. |
| Query API; search service | `zortex.query` (plain data, export); matching and ranking moved from the picker to `services/search`. |
| Cleanups | One digest module (email sending works again), smaller event bus, dead code removed, `min_score` dropped. |
| Planner, KR links, OKR weight, app rename | `:ZortexPlan` day planner with templates and ranked candidates; explicit `[…/-KR1]` and task links; link text limited to `[A-Za-z0-9 _-().]`; OKR bonus in project scoring; `app/` → `legacy/`, `deployment/` → `app/` with a Notes tab. |
| Actions registry | `actions.lua` generates commands, keymaps and `api.actions`; `require("zortex")` exposes every service; `:checkhealth zortex`; README rewritten with a generated command table. |
| Hover preview; planner keys | `ui.preview.hover` previews the link under the cursor; planner `i`/`o`/`O` place an item on a line, `p` appends it as a list item and stays in the side buffer. |
| Go grammar | `app/syntax` ports `core/syntax` and passes every AST fixture; `zortex parse`/`sections`; `nix build .#zortex`. |
| Dashboard file viewer | The Notes tab browses every file in the folder; PDFs, images, media and text open in the browser (ranges, sandboxed HTML/SVG). |
| Go resolver and search | `app/notes`, `app/links`, `app/search`; `tests/gen_links.lua` writes `resolve.json` and `search.json`, checked by `test_links` and the Go tests; `zortex resolve`/`search`; search uses the notes index's file order. |

## New modules

| module | purpose |
|---|---|
| `core/document.lua` | Cached note snapshots (file by mtime, modified buffer by changedtick). |
| `core/notes.lua` | Recursive note list and header index (`find_by_name`, `find_by_tag`); archived notes excluded. |
| `core/entity.lua` | `Entity` base class plus `registry(spec)` lookup API, shared by projects and areas. |
| `core/link_index.lua` | Every link in every note with its resolved target; backlinks, unresolved links; persisted in `.z/link_index.json`. |
| `services/okr/init.lua`, `objective.lua` | Objective entities (`O/` namespace) and key results with computed progress. |
| `services/agenda.lua` | Agenda over calendar entries, due tasks and due projects; `review()` findings. |
| `features/preview.lua` | Floating preview of a link's target. |
| `ui/review.lua` | Weekly review buffer over `agenda.review()`. |
| `services/search_history.lua` | Decayed open counts per note and section (`.z/search_history.json`), used to boost search. |
| `core/syntax.lua` | The Zortex grammar: line kinds, list items, blocks, inline spans (plain Lua). |
| `core/item.lua` | Shared list-item type for tasks, calendar entries and key results. |
| `core/state.lua` | Versioned JSON state files in `.z` with atomic writes and recovery. |
| `query.lua` | Plain-data API over notes, structure and the domain; JSON export. |
| `actions.lua` | Every user-facing action once; commands, keymaps, `:ZortexHelp` and the README table come from it. |
| `health.lua` | `:checkhealth zortex`. |
| `services/search.lua` | Structural search index, matching and ranking (moved out of the picker). |
| `tests/gen_ast.lua`, `tests/fixtures/ast/`, `tests/fixtures/syntax/` | Syntax conformance fixtures and their generator. |
| `tests/gen_links.lua`, `tests/fixtures/resolve.json`, `search.json` | Resolver and search conformance fixtures and their generator. |
| `app/syntax`, `app/notes`, `app/links`, `app/search`, `app/cmd/zortex` | Go port: grammar, notes index, resolver, search, CLI. |
| `services/projects/init.lua` | Projects registry, `query`, `tasks`, `update_progress`. |
| `services/projects/project.lua` | `Project` class (tasks, stats, rollup, points, relations). |
| `services/projects/score.lua` | Scoring and sort comparators (moved out of the picker). |
| `services/projects/relations.lua` | Schedule index, key results, areas. |
| `services/areas/init.lua`, `area.lua` | Areas registry and `Area` class. |
| `services/xp/stats.lua` | XP views and season actions; replaces the removed `services.xp` entry points. |
| `tests/*` | Runner, helpers, fixtures, 8 test files. |
| `doc/Projects.md`, `doc/Architecture.md`, `doc/Changes.md` | Documentation. |

## Removed modules

| removed | replaced by |
|---|---|
| `services/projects.lua` | `services/projects/` package (same `require` path) |
| `services/areas.lua` | `services/areas/` package (same `require` path) |
| `services/ids.lua` | `services/tasks.find_task_by_id` (it was a copy) |
| JSON tree cache (`stdpath("cache")/zortex/trees.json`) | in-memory document cache; the old file can be deleted |
| `core/workspace.lua` document manager (1,136 lines: change tracking, undo queue, debounced reparsing, autosave stubs) | `core/workspace.lua` editing layer (~150 lines) over buffers/files, reads via `core/document` |
| `services/okr.lua` | `services/okr/` package (same `require` path) |
| `stores/base.lua`, `stores/persistence_manager.lua`, `:ZortexSaveStores`, `core.persistence_manager` config | `core/state` (stores save when they change) |
| `parser.CodeBlockTracker`, `detect_section_type`, `calculate_level`, `scan_sections`, `build_section_path`, `find_section_end`, `get_heading_level`, `parse_heading`, `parse_label`, `is_bold_heading`, … | `core/syntax` and the document tree (`doc.syntax`, `doc:node_at`, `node.end_line`) |
| `ui/commands.lua`, `ui/keymaps.lua` | `actions.lua` |
| `autoload/health/zortex.vim` (checked the old Node preview server) | `lua/zortex/health.lua` |
| the 37 line patterns in `features/highlights.lua`, the regexes in `folding.lua` and `calendar_entry.from_text` | `core/syntax` |
| `stores/calendar.set_all_entries` | removed (unused; it rewrote the whole calendar) |

## Behaviour changes you may notice

**Planning and links**
- **`:ZortexPlan [date]`** (`m`): calendar day from a template plus ranked
  tasks, projects, key results and areas to put on it.
- **Key results link to themselves** (`[O/…/-KR1]`), and `-text` link
  components match list items by key or text prefix (checkbox and
  attributes ignored).
- **Generated link text** is limited to `[A-Za-z0-9 _-().]`: area links like
  `[A/#4 Learning & Education/…]` are now written `[A/#4 Learning/…]` (same
  target). Existing links keep resolving.
- **Review:** no repeated `KR1: KR1:`, single spaces before links.
- **Projects:** OKR-aligned projects rank higher (`score`, `priority`, new
  `okr` sort) and show an `OKR` indicator.

**Repository layout**
- `app/` (the old Next.js/Node app) is now `legacy/`; `deployment/` (the
  Flask server) is now `app/`, with a Notes tab (search and browse the synced
  notes folder). Docker/Nix paths were updated; the NixOS module gained
  `notesDir`, `notesGroup`, `notesSpecial`.

**Commands and keys** (all generated from `actions.lua`; `:ZortexHelp` lists them)
- **New:** `:ZortexBacklinks` (`b`), `:ZortexSearchArticles` (`Z`, was a
  second binding for search), `:ZortexSectionNext` / `Prev` / `Parent`
  (`]`, `[`, `^`), `:ZortexFoldsUpdate` (`r`), `:ZortexArchiveSection` (`a`),
  `:ZortexHelp` (`?`), `:ZortexReview` key `w`, `:ZortexTaskConvert` key
  `tt`, `:ZortexXPAreas` key `xa`. Keys are under `keymaps.prefix`.
- **Merged:** `:ZortexXPInfo` → `:ZortexXPStats` (they did the same thing);
  `:ZortexSystemStatus` and `:ZortexDebug` → `:ZortexStatus`. The `xi` key is
  gone (use `xs`).
- **Fixed:** `:ZortexCalendarDigest` called a function that didn't exist;
  `:ZortexTaskConvert` never wrote the converted line; `:ZortexSeasonStart`
  without arguments now prompts.
- **Configurable:** `keymaps.mappings = { <action id> = key | {keys} | false }`
  and `keymaps.enabled`.
- **API:** `require("zortex")` exposes services by name and
  `actions.<id>()`; the old ad-hoc tables (`api.task`, `api.search.structural`,
  `api.calendar.digest`, `api.xp.season`, …) are replaced by
  `z.actions.task_toggle()`, `z.search`, `z.xp`, … (see the README).

**Parser**
- **Indented code fences count** (```` ``` ```` inside a list item): lines
  inside them are no longer headings, labels, tasks or links. Closing fences
  must use the same character, be at least as long, and carry no info string.
- **`$$` lines open and close math blocks**; nothing inside is structure.
- **A task is never a label:** `- [ ] Do this:` is a task, not a section.
- **`- Label:`** labels are named without the bullet (`:Label`, not
  `:- Label`).
- **Key results with checkboxes are tasks**, so `:ZortexTaskToggle` works on
  `- KR1: [ ] …` lines.
- **Attributes and file paths must start a word**, so `and/or` is no longer
  a file path and `me@example.com` is not an attribute.
- **`@a(...)` under the cursor opens its area** (the lookup was broken).
- **Highlighting** comes from the same syntax: bulleted labels, `+`/`*`
  bullets, ordered and time markers, and links inside bold text are now
  highlighted; operators and punctuation are never painted inside links or
  code.

**Links**
- **Generated project links start with `P`:** `[P/#1 Programming/#1.4 - zortex]`
  and `[P/Flipping/#Subaru outback]`. Links you've already written resolve as
  before.
- **Generated area links start with `A`:**
  `[A/#1 Personal Foundation/#1.2 Vitality/:Fitness]`.
- **An article component also matches tagged notes**, after notes that declare
  the alias. `[P/…]` therefore covers every `@P` note, and `[Me/…]` now reaches
  notes tagged `@Me` when no note is named `Me`.
- **Typed components are never split as queries.** `#R & D` is a heading.
- **Link resolution includes notes in subfolders.** Before, only top-level
  notes were searched.

**Notes and structure**
- **Archived notes are skipped** in link resolution and project lists (files
  named `archive.*` or tagged `@Archive`). Archive files created by
  `features/archive` now get an `@Archive` tag automatically. Use
  `[@Archive/…]` to reach them.
- **Heading text no longer includes attributes.** This affects breadcrumbs,
  search results, project names and keys.
- **Aliases form one article.** `@@Projects` + `@@P` is a single article
  named `Projects`, so breadcrumbs start with `Projects`, not `P`.

**Search**
- **`Config.ui.search` is now used** (see the search section of
  Architecture.md). With one untyped token, only articles and H1 headings
  match structurally, per your `token_filters`; typed `#`/`:` tokens search
  every depth. `<C-t>` toggles article mode.
- **Search works like the original search service again** (removed in
  `28a3ce2`). Words match a section's path in order, so `2 4` finds
  `1 › 2 › 3 › 4` but not `4 › 2`. Results use the original scoring (word
  quality plus a type bonus favouring articles, then headings by level), are
  grouped by file in document order, list each match's direct sub-sections,
  and show the full breadcrumb. `@@`, `#`, `:` and `*` restrict a word to one
  section type, and `_` is a space. This replaces Telescope's fuzzy order.
  Archived sections are labelled `(archive)` and come after live ones.
- **Article mode matches article names**, as it originally did, rather than
  article content.

**XP**
- **Project XP is keyed by project key**
  (`Projects/1 Programming/1.4 - zortex`) instead of the old link string.
- **Area XP is keyed by area key**
  (`Areas/4 Learning & Education/4.1 Education & Skills`) instead of raw
  attribute paths like `#4.1`.

**Tasks**
- **`TaskToggle` and friends work in every note**, including standalone `@P`
  projects, and award XP there.
- **Toggling only changes the checkbox and `@done(...)`.** Other attributes,
  tags, their order and the indentation stay exactly as written.

**Calendar**
- **Calendar edits from the UI are line edits.** Adding an entry inserts one
  line under its date (styled like the other entries; untimed entries get
  `- `), or adds the date heading in date order. Editing or deleting changes
  exactly one line. Date headings stay when their last entry is deleted.
- **If `calendar.zortex` is open in a buffer, edits go to the buffer** (save
  it as usual); otherwise to the file.
- **The calendar store reloads by itself** when the file or buffer changes.
- **The calendar digest panel shows project tasks and projects due** that day,
  not just calendar entries.

**OKR**
- **Objectives have `O/` links** (`[O/#Current/#3M-2026-Q1 Establish …]`) and
  **KR progress is computed** from the projects a KR links to (points done /
  points). A checked KR counts as done. The projects picker shows it.

**Links**
- **Generated links stop a component at `/`.** A heading like
  `… good habits/routine` is linked as `#… good habits`; prefix matching
  still finds the same heading.
- **New commands:** `:ZortexLinkPreview` (`<prefix>K`), `:ZortexBrokenLinks`,
  `:ZortexLinkIndexRebuild`, `:ZortexReview [days]`.
- **Search remembers what you open.** Notes and sections you open from search
  rank higher among similar matches, fading over days (`access_decay_rate`,
  `history.score_decay`).
- **Completion suggests only links that resolve**, based on what's typed
  so far.

## Bug fixes

**Projects and links**
- `:ZortexProjects` required a missing module (`zortex.legacy.ui.telescope.projects`).
- The projects service called undefined functions (`to_project`,
  `get_project_stats`, `get_project_path`, `projects.load`,
  `update_all_project_progress`, `services.projects.progress`). It also
  returned a name-keyed map, which the picker iterated with `ipairs` and so
  got nothing.
- Attributes leaked into project names and links, so built links never
  matched `find_section_by_link`.
- `find_section_by_link` used exact, case-sensitive matching on direct
  children only, so `[P/#1.4 - zortex]` (which skips `# 1 Programming`)
  never resolved a project.

**OKR**
- `for … in objective.key_results do` was missing `ipairs`.
- `linked_projects` was a map but was iterated as a list.
- The code called `parser.parse_attributes`, which doesn't exist.
- It read `section.tasks`, which was never filled.
- It parsed headings from text without `##`. As a result, KRs were never found.

**Tasks**
- Converting a line into a task called `workspace.calendar()`, which doesn't
  exist, and crashed.

**Structure and navigation**
- `navigate_section` and archive merging compared levels on two different
  scales.
- `extract_line_identifier` took a task's `[ ]` checkbox for a link and
  produced an empty `%` query.
- `links.jump_to_location` had a fallback that called a nonexistent API.

**Stale modules**
- `ui/skill_tree.lua`, `ui/commands.lua` and `api.lua` required the removed
  `services.xp`, and called functions that didn't exist (`get_stats`,
  `get_season_status`, `show_xp_overview`, an undefined `skills` global,
  `Config.get`).
- `ui/calendar/init.lua` required the removed `services.calendar`; its
  `M.add_entry` and `M.load` were undefined.

**XP store**
- `stores/xp` read `cfg.project.season_curve` and `cfg.seasons.tiers`, but the
  config defines `xp.season.level_curve` and `xp.season.tiers`. Recording XP
  during an active season always threw.
- `get_area_xp` didn't load the store first.
- The level loops could spin forever on a flat curve.
- The skill tree used highlight groups that were never defined.

**Search**
- The search index included the synthetic `Root` node in every path, so a
  query like `ro` matched every section.

**Search setup and calendar view**
- `init.lua` called `ui.telescope.search.setup()`, which didn't exist.
  `search.lua` also required Telescope when it loaded, so setup failed without
  Telescope installed.
- The calendar crashed on open (`str_byteindex: index out of range`). Cell
  positions are display columns, but they were converted as character
  indices, which breaks on rows with wide icons.

**Editing, links, tasks (latest change set)**
- `stores/calendar.save()` regenerated `calendar.zortex` from parsed entries
  on every add, edit or delete (and again via the persistence manager). It
  dropped the header and notes, re-sorted entries by priority, re-indented
  them and removed empty dates.
- The calendar's delete dialog listed `get_entries_for_date` (sorted, with
  recurring entries) but deleted by index from the raw per-date list, so it
  could delete the wrong entry.
- Toggling a task rebuilt the line from parsed attributes: bare tags and area
  lists became `@context(table: 0x…)` / `@area(table: 0x…)`, `@p1` became
  `@p(1)`, and attributes were reordered.
- `attributes.remove_attribute` collapsed all whitespace on the line, so
  un-completing a task lost its indentation.
- `parser.extract_all_links` treated task checkboxes (`[ ]`, `[x]`) as links,
  so calendar tasks and KRs carried bogus links.
- Keymaps pointed at commands that don't exist: `gx` → `OpenLink` (the
  command is `LinkOpen`), `P` → `ProjectsOpen`, `u` → `UpdateProgress`, `r` →
  `FoldsReload`.

## Duplicates removed

- every line classifier (tree, highlights, folding, calendar, tasks, link
  extraction, archive) → `core/syntax`
- three task/entry/KR line parsers → `core/item`
- two persistence mechanisms (base store + manager, ad-hoc JSON) → `core/state`
- two digest formatters → `services/digest`
- two logger implementations in one file → `core/logger`
- 5 header parsers → `parser.parse_header`
- 2 level scales → `constants.SECTION_HIERARCHY`
- 3 link builders → `link_resolver.build_link` / `link_for_node`
- 3 "find the enclosing heading" walkers → `projects.at`
- 2 line-search loops in `link_resolver` → `search_lines`
- 2 AND/OR splitters → `parser.split_query`
- 2 media-extension checks in `features/links.lua` → `is_media`
- duplicate task-id helpers (`services/ids.lua`)
- project/area structure code → `core/entity`
- per-feature link resolution (schedule index, OKR) → `core/link_index`
- three "upcoming items" builders (calendar view panel, digest note, email
  digest) → `services/agenda`
- completion's own file cache, structure scanner and section-bounds walker →
  the resolver plus `section_items`
- the workspace's document copy, change log and reparse timers → buffers +
  `core/document`

## Migration notes

- **Stored XP:** existing area XP stored under raw keys (`#4.1`) and project
  transactions keyed by old link strings won't be picked up by the new keys.
  Those keys were already inconsistent: the skill tree never matched them.
  Starting a new season is the simplest reset. Moving old area totals over is
  a one-off: resolve each key with
  `require("zortex.services.areas").resolve("Areas/" .. old_key)` and add its
  XP under `area.key`.
- **Old tree cache:** `~/.cache/nvim/zortex/trees.json` is no longer used and
  can be deleted.
- **`fs.get_all_note_files()`** is now recursive and kept only as an alias.
  Prefer `require("zortex.core.notes").files()`, which also skips archives.
- **Removed or renamed functions:**

  | old | new |
  |---|---|
  | `link_resolver.find_section_by_link` | `link_resolver.resolve_node` |
  | `find_article_files` | `notes.find_by_name` |
  | `search_component_in_files` / `search_in_buffer` | `search_lines` |
  | `parser.find_section_start` | removed (unused) |
  | `parser.extract_tags_from_lines` | `parser.parse_header` |
  | `parser.parse_okr_date` | `okr.parse_objective` |
  | `section.create_from_line` | removed (unused) |
  | `Section:build_link` | `link_resolver.link_for_node` |

- **Workspace API:** the old `Document` methods (`change_line`, `add_lines`,
  `save`, `undo`, …) and the `projects()`/`areas()`/`okr()` accessors are gone.
  Use `core/workspace.set_lines` / `set_line` / `insert_lines` /
  `delete_lines` for edits and `core/document` (or the projects/areas/OKR
  registries) for reads.
- **`stores/calendar`:** use `delete_entry(entry)` or `delete_entry_by_index`
  (which now indexes the list `get_entries_for_date` returns).
- **Link index file:** `notes_dir/.z/link_index.json` is created on first use;
  deleting it just triggers a full rebuild.
- **Search history:** `notes_dir/.z/search_history.json` starts empty; the
  old in-memory history is not migrated. Delete the file (or call
  `require("zortex.services.search_history").clear()`) to reset ranking.
- **State files** keep their names (`xp_state.json`, `notifications_state.json`)
  and are read as version 1, so nothing is lost. The link index is rebuilt
  once (its version changed with the new extraction).
- **Logs** move from a cwd-relative `.z/logs` to `notes_dir/.z/zortex.log`.
- **Parser helpers:** code that called the removed `parser.*` structure
  functions should use `require("zortex.core.document").get(path)` and its
  `syntax`, `info(lnum)`, `items()`, `node_at(lnum)` and the tree, or
  `core/syntax` directly for single lines.
- **Search:** `require("zortex.ui.telescope.search")` still exposes
  `setup`, `query_index`, … (re-exported); new code should use
  `require("zortex.services.search")`.

## Not done yet / ideas

Ideas, deferred integrations and the web app plan are collected in
[Wishlist.md](Wishlist.md).
