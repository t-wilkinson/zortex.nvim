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
3. **Projects and areas as entities** on a common base (`core/entity`), with
   relations to the calendar, OKRs and areas resolved by key.
4. **Fixes:** every module now loads, `setup()` completes, the calendar opens,
   and the XP pipeline works end to end.
5. **A headless test suite:** 119 tests, no dependencies.

## Commits

| commit | summary |
|---|---|
| Make projects first-class | Shared core, one link resolver, projects API, OKR rewrite, picker rebuilt, first round of fixes. |
| Areas as first-class objects | `core/entity` base, `P/` project links, areas API, XP keyed by area, stale `services.xp` / `services.calendar` callers fixed, task toggling in any note. |
| Search setup, calendar crash, docs | `search.setup()` with config overlay and implemented options, calendar selection crash, these docs. |
| Hierarchy-first search ranking | The picker keeps the search's own order instead of re-sorting by fuzzy score; the synthetic root is no longer matchable. |
| Restore ordered path search | Words match a section's path in order (last word = the section), with the original scoring, file grouping, document order, direct sub-sections and full breadcrumbs. |

## New modules

| module | purpose |
|---|---|
| `core/document.lua` | Cached note snapshots (file by mtime, modified buffer by changedtick). |
| `core/notes.lua` | Recursive note list and header index (`find_by_name`, `find_by_tag`); archived notes excluded. |
| `core/entity.lua` | `Entity` base class plus `registry(spec)` lookup API, shared by projects and areas. |
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

## Behaviour changes you may notice

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

**This change set**
- `init.lua` called `ui.telescope.search.setup()`, which didn't exist.
  `search.lua` also required Telescope when it loaded, so setup failed without
  Telescope installed.
- The calendar crashed on open (`str_byteindex: index out of range`). Cell
  positions are display columns, but they were converted as character
  indices, which breaks on rows with wide icons.

## Duplicates removed

- 5 header parsers → `parser.parse_header`
- 2 level scales → `constants.SECTION_HIERARCHY`
- 3 link builders → `link_resolver.build_link` / `link_for_node`
- 3 "find the enclosing heading" walkers → `projects.at`
- 2 line-search loops in `link_resolver` → `search_lines`
- 2 AND/OR splitters → `parser.split_query`
- 2 media-extension checks in `features/links.lua` → `is_media`
- duplicate task-id helpers (`services/ids.lua`)
- project/area structure code → `core/entity`

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

## Not done yet / ideas

- **`:ProjectRename`:** rename or renumber a project heading and rewrite every
  link to it.
- **Search ranking and history** (`min_score`, `access_decay_rate`, `history`
  in the config).
- **`doc/Search.md`** describes more token types (`@@`, `@`, `*`, escaped
  spaces) than the picker implements.
- **Calendar highlights** in `ui/calendar/view.lua` still mix display and byte
  columns (the `shift_hl` / `icon_width` adjustment). It renders correctly with
  the default icons, but switching it to `display_col_to_byte` would remove
  the special case.
