# Zortex wishlist

Features, integrations and plans that are agreed in direction but not built
yet. Each entry says what it is, why it matters, and what it builds on, so it
can be picked up without re-deriving the design. For what exists today see
[Architecture.md](Architecture.md); for what changed, [Changes.md](Changes.md).

Contents:

1. [Weekly review with actions](#1-weekly-review-with-actions)
2. [Area overview](#2-area-overview)
3. [Connecting OKR, PARA, calendar and notes](#3-connecting-okr-para-calendar-and-notes)
4. [Search](#4-search)
5. [Editing and maintenance](#5-editing-and-maintenance)
6. [The web app](#6-the-web-app)

---

## 1. Weekly review with actions

`:ZortexReview` shows the findings of `agenda.review()` (overdue, due soon,
completed, stale/unscheduled projects, projects without a next action, KRs
without projects, objectives without KRs, areas without projects, broken
links). Today it is read-only. The goal is a review you can *work through*:
every finding has the obvious next step one key away, and the review records
what happened.

**Actions per line** (buffer-local keys in `zortex://review`, each a line
edit through `core/workspace`, then `r` refresh):

| finding | action |
|---|---|
| overdue / due soon task | `x` complete · `d` set or move `@due(…)` · `s` schedule (calendar entry on a picked day linking the task's project) |
| completed | nothing; it's the "wins" list |
| stale / unscheduled project | `s` schedule a block · `n` add a next action · `z` mark `@someday` (excluded from stale) · `a` archive if done |
| no next action | `n` add a task under the project (prompt) |
| KR without projects | `l` link a project (projects picker → append `[P/…]` to the KR line) |
| objective without KRs | `k` add `- KRn: [ ] …` under it |
| area without projects | `p` create a project heading with `@a(…)` for the area |
| broken link | `f` fix: structural search with the link text as the prompt, replace the link with the chosen result's canonical link |

**Plan the week.** A second pass after the findings: list open tasks of
active projects (sorted by `projects/score`), pick some with `<Tab>`, choose
days, and write them as calendar entries linked to their project. This is
where the calendar becomes the plan, not just a log.

**Review history.** On closing a review, save a snapshot to
`.z/reviews.json` (`core/state`): date, counts per finding, points completed
per area and per objective, KR progress. The next review shows deltas
("3 fewer overdue", "Vitality: 0 points for 3 weeks"), and the snapshots are
the data for trends (section 3).

**Builds on:** `agenda.review()`, `ui/review.render` (already returns a
line → location map), `core/workspace`, `stores/calendar.add_entry`,
`services/search`, `projects.query`.

## 2. Area overview

A page per PARA area that answers "how is this part of my life going?"
(`:ZortexArea [key]`, picker over `areas.all()` when no key; also `<CR>` on an
area in the skill tree).

```
@@Area: 1.2 Vitality
Level 3 · 420 XP (this season 120) · last activity 2026-10-08

# Objectives
- [O/#Current/#3M-2026-Q1 Establish and maintain good habits]  45%
  - KR2 Make list of habits and routines  60%  [P/#1 Personal/#Habits]

# Projects
- [P/#1 Personal/#Habits]  1/2 done · 3 pts open · next: Morning routine
- done: …

# Upcoming
- 2026-10-14 07:00 Run  (calendar, linked)

# Notes
- [Running log]  (notes tagged or attributed with this area)

# Balance (last 4 weeks)
points done per week: 3 · 0 · 5 · 2
```

- **Objectives and KRs:** `area:objectives({ descendants = true })` with
  progress.
- **Projects:** `area:projects({ descendants = true })`, split active/done,
  with rollups and the top-scored next task.
- **Upcoming:** agenda items whose project belongs to the area.
- **Notes (the "Resources" side of PARA):** notes whose header carries
  `@a(…)` / `@area(…)` for this area, plus notes linking to the area. This
  needs one small grammar decision: header attribute tags (`@a(1.2)` on its own
  header line) already parse as tag lines; resolve them like project `@a`.
- **Activity and balance:** `@done` dates of tasks in the area's projects,
  calendar entries linked to them, and review snapshots (section 1).
- **Also:** an all-areas dashboard (one line per area: level, active projects,
  points this week, last activity) to spot neglected areas.

**Builds on:** `services/areas` (Area entities, `keys_for`, XP),
`services/okr`, `services/agenda`, `core/link_index` (backlinks into the area),
`zortex.query.areas()`.

## 3. Connecting OKR, PARA, calendar and notes

Deferred for now; listed so the pieces fit together later.

- **Calendar entries that point at tasks**, not just projects. A task with
  `@id(abc12)` gets a link form (for example `[T/abc12]`); a calendar entry
  containing it is that task's time block. Completing either side completes
  both (`task:completed` handler using `tasks.find_task_by_id`).
- **Inbox capture.** `inbox.zortex` (or `@Inbox` notes) plus a quick-capture
  command; the review gets an "Inbox (n)" section with `m` to move an item
  into a project or onto the calendar.
- **Key results with their own measure.** `@progress(3/10)` or
  `@target(10) @current(3)` on a KR line for KRs not backed by projects;
  `KeyResult:progress()` prefers it.
- **Trends.** Points completed per area and per objective per week, from
  review snapshots and `@done` dates; shown in the area overview and the
  review.
- **Recurring project tasks** (`@repeat(weekly)` on a project task, like
  calendar entries) and **task dependencies** (`@depends(id)`, already in the
  task schema but unused).

## 4. Search

- **Breadcrumb display per token count** (`ui.search.breadcrumb_display`, kept
  in the config, reserved): shorten breadcrumbs depending on how many words
  were typed (article only for one word, article + H1/H2 for two, …).
- **Search inside a folder:** a `z/` or `dir:z/projects` prefix, or a picker
  scope, limiting `services/search` to notes under a directory.
- **Full-text tokens** described in [Search.md](Search.md) (`@tag` words,
  escaped spaces everywhere) that the picker does not implement yet.

## 5. Editing and maintenance

- **`:ZortexProjectRename`:** rename or renumber a project heading and rewrite
  every link to it (`link_index.references` knows each one).
- **Broken-link diagnostics** with `vim.diagnostic` from
  `link_index.unresolved()`.
- **Backlinks panel** for the section under the cursor
  (`query.backlinks(path, lnum)`).
- **Calendar view highlights:** `ui/calendar/view.lua` still adjusts icon
  widths by hand (`shift_hl` / `icon_width`); switch it to
  `display_col_to_byte`.
- **Archive revert:** `features/archive.revert_archive` is a stub.

## 6. The web app

### Goal

A small, read-mostly web app for the notes, deployed as a **NixOS service on
a Raspberry Pi 4** that already runs other servers. It reads a **synced
zortex directory** (for example Syncthing) and must work **without Neovim**.
The important features are:

1. **Note search** with the same ordered-path matching and ranking as the
   plugin.
2. **Directory navigation and search**, especially `z/*` (folders, note
   titles and aliases, tags, archived notes marked).
3. **Rendering Zortex files** faithfully: structure, tasks, attributes,
   links that work, tables, code, math, footnotes.

Editing is not a goal (at most, later, appending to an inbox).

### Constraints that shape the design

- **Memory.** It shares RAM with other services, so: one process, an
  in-memory index of a few MB for a personal notes folder, no headless
  browser, no Node build at runtime. Target well under 100 MB resident; set a
  systemd `MemoryMax` so it can't crowd out neighbours.
- **No Neovim.** The grammar has to exist outside the plugin. `core/syntax` is
  already plain Lua with no `vim.*` calls, and its output is pinned by the
  conformance fixtures (`tests/fixtures/ast/*.json`, every construct in
  `tests/fixtures/syntax/sample.zortex`).
- **Synced folder.** Files change underneath the app at any time. Watch the
  directory (inotify), re-parse changed files only, and ignore sync
  artefacts (`.syncthing.*.tmp`, `*.sync-conflict-*`, `.stversions/`,
  `.stfolder`). Never write into the synced folder: app state (its own
  search history, caches) lives in the service's state directory, so it
  can't cause sync conflicts with `.z/` files written by Neovim.

### Recommended shape

- **Language: Go.** A single static binary, small resident memory, a mature
  standard library for HTTP and file watching, and simple Nix packaging
  (`buildGoModule`). Rust would also fit; Python (Flask, like `deployment/`)
  is the easiest to write but the heaviest at runtime.
- **Grammar: port `core/syntax` (~700 lines) to a Go package** and run the
  conformance fixtures as its test suite: parse each fixture, compare with the
  JSON. The fixtures make drift visible the moment either side changes.
  *Alternative:* embed a Lua 5.1 interpreter (gopher-lua) and run
  `core/syntax.lua` unchanged. That's one grammar instead of two, at the cost
  of slower parsing and an interpreter in the process. Worth a quick
  measurement on the Pi before choosing.
- **What else to port (smallest first):**
  - header and notes index (names, aliases, tags, archived), from
    `core/notes`
  - the section tree, from `core/section` (sections are already in the
    syntax output)
  - **link resolution**, from `utils/link_resolver`: article-or-tag, prefix
    heading match at any depth, first match canonical, archives skipped. This
    is the biggest piece; generate resolver fixtures the same way (link →
    expected file:line) from the plugin.
  - **structural search**, from `services/search`: tokenizer, ordered-path
    dynamic program, scoring, file grouping, direct children. Small and pure.
  - backlinks: invert the resolved links of all notes at index time.
- **Rendering: server-side HTML from the AST.** Each line kind and span type
  maps to an element and a CSS class (the highlight groups in
  `features/highlights.lua` are the colour reference). Links become anchors
  to `/n/<rel>#L<lnum>` using the resolved target. Math via KaTeX and code
  highlighting loaded only on pages that need them. Minimal JavaScript:
  search-as-you-type and keyboard navigation (htmx or a few dozen lines of
  plain JS).
- **Routes:**
  - `/` folder view (root)
  - `/d/<dir>` folder view (`z/…`)
  - `/n/<rel>` rendered note with an outline sidebar and backlinks
  - `/search?q=` results as breadcrumbs, then matching lines
  - `/api/search`, `/api/note/<rel>`: JSON, same shapes as `zortex.query`
- **Later, with the domain ported:** project progress bars in
  `projects.zortex`, KR progress in `okr.zortex`, a calendar view of
  `calendar.zortex`, the weekly review page, and the area overview (section
  2). The JSON shapes are already defined by `zortex.query` (`projects()`,
  `objectives()`, `agenda()`, `review()`), so the plugin and the app can
  share fixtures for those too.

### Nix

- The flake exports `packages.<system>.zortex-app` (`buildGoModule`) and
  `nixosModules.zortex-app`.
- **Module options:**
  - `services.zortex-app.enable`
  - `notesDir` (the synced folder)
  - `listenAddress` / `port`
  - `user` / `group` (or `DynamicUser` with read access to the folder)
  - `memoryMax`
  - `extraArgs`
- **systemd unit:**
  - `ReadOnlyPaths = [ notesDir ]`
  - `StateDirectory = "zortex-app"`
  - `ProtectSystem = "strict"`, `ProtectHome` (unless the folder is under
    `/home`), `NoNewPrivileges`, `PrivateTmp`
  - `MemoryMax` from the option
  - `Restart = "on-failure"`
- **Exposure:** bind to localhost and publish it through the existing reverse
  proxy with authentication (or Tailscale only). The notes are private.
- **Notifications:** the `deployment/` server (Flask + SQLite + ntfy) can stay
  a separate service, or later become a route in the app.

### Phases

1. **Grammar:** Go port of `core/syntax` passing all conformance fixtures,
   plus a plugin-side generator for resolver and search fixtures.
2. **Index and navigation:** notes index, folder views, rendered notes (no
   link resolution yet), file watching, the Nix package and module.
3. **Links and search:** resolver plus fixtures, working links, backlinks,
   structural search page.
4. **Domain views:** projects, OKR, calendar, review and area overview, using
   the `zortex.query` shapes.

### Open questions

- Port the grammar, or embed Lua? Measure gopher-lua parse time for the whole
  notes folder on the Pi first.
- Which sync tool, and does it run on the Pi (Syncthing) or is the folder
  pushed (git, rsync)? This decides whether to watch the folder or poll it.
- Does the app need its own search history? It should be kept separate from
  `.z/search_history.json` to avoid sync conflicts.
