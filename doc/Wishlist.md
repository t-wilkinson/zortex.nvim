# Zortex wishlist

Features, integrations and plans that are agreed in direction but not built
yet. Each entry says what it is, why it matters, and what it builds on, so it
can be picked up without re-deriving the design. For what exists today see
[Architecture.md](Architecture.md); for what changed, [CHANGELOG.md](../CHANGELOG.md).

Contents:

1. [Weekly review with actions](#1-weekly-review-with-actions)
2. [Area overview](#2-area-overview)
3. [Connecting OKR, PARA, calendar and notes](#3-connecting-okr-para-calendar-and-notes)
4. [Search](#4-search)
5. [Editing and maintenance](#5-editing-and-maintenance)
6. [The web app](#6-the-web-app)
7. [Tree-sitter grammar](#7-tree-sitter-grammar)
8. [Agreed on 2026-10-16](#8-agreed-on-2026-10-16)
9. [Agreed on 2026-10-22](#9-agreed-on-2026-10-22)

---

## 1. Weekly review with actions

`:ZortexReview` shows the findings of `agenda.review()` (overdue, due soon,
completed, stale/unscheduled projects, projects without a next action, KRs
without projects, objectives without KRs, areas without projects, broken
links). The goal is a review you can *work through*: every finding has the
obvious next step one key away, and the review records what happened.

**Actions per line: done.** Every row of this table is a key in
`zortex://review` (`lua/zortex/keys.lua` lists them, `?` shows them), plus
`f` (week's focus), `m` (inbox to its project), `t` (tomorrow, same time)
and `u` (undo):

| finding | action |
|---|---|
| overdue / due soon task | `x` complete · `d` set or move `@due(…)` · `s` schedule (calendar entry on a picked day linking the task's project) |
| completed | nothing; it's the "wins" list |
| stale / unscheduled project | `s` schedule a block · `n` add a next action · `z` mark `@someday` (excluded from stale) · `a` archive if done |
| no next action | `n` add a task under the project (prompt) |
| KR without projects | `L` link a project (projects picker → append `[P/…]` to the KR line) |
| objective without KRs | `R` add `- KRn: [ ] …` under it |
| area without projects | `p` create a project heading with `@a(…)` for the area |
| broken link | `f` fix: structural search with the link text as the prompt, replace the link with the chosen result's canonical link |

**Plan the week.** Partly done: the weekly review opens the week's entry
in `reviews.zortex`, and `f` picks its focus projects, which the planner
ranks first ([Planning](Planning.md#the-week)). Still to do: a second pass
that lists the focus projects' open tasks, picks some with `<Tab>`, chooses
days, and writes them as calendar entries linked to their project.

**Review history.** On closing a review, save a snapshot to
`.z/reviews.json` (`core/state`): date, counts per finding, points completed
per area and per objective, KR progress. The next review shows deltas
("3 fewer overdue", "Vitality: 0 points for 3 weeks"), and the snapshots are
the data for trends (section 3).

**Builds on:** `agenda.review()`, `ui/review.render` (already returns a
line → location map), `core/workspace`, `stores/calendar.add_entry`,
`services/search`, `projects.query`. Snapshots go in a synced `core/state`
file (one per device, or merged on conflict: see section 9).

## 2. Area overview

A page per PARA area that answers "how is this part of my life going?"
(`:ZortexArea [key]`, picker over `areas.all()` when no key; also `<CR>` on an
area in the XP view).

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

- **Calendar entries that point at tasks**: done with task copies and
  references ([Planning](Planning.md#the-day-on-the-calendar)). No `[T/…]`
  component: a `-` component matching an `@id` covers stable task links
  (section 8).
- **Inbox capture**: mostly done. `inbox.zortex` is opened with
  `:ZortexOpenInbox` and filled from the web app (offline too); the reviews
  list it first, with `m` to move an item to its `@project`. Still missing: a
  quick-capture command in Neovim that adds a line without opening the note.
- **Key results with their own measure.** `@progress(3/10)` or
  `@target(10) @current(3)` on a KR line for KRs not backed by projects;
  `KeyResult:progress()` prefers it.
- **Trends.** Points completed per area and per objective per week, from
  review snapshots and `@done` dates; shown in the area overview and the
  review.
- **Shared lines for one person.** `@share(bob)` on a calendar line puts it
  only in Bob's feed: `/calendar.ics?to=bob` with a token per person (a
  `-share-tokens` file of `name:token` lines), so a line for the kids' pickup
  reaches the other parent's Cozi calendar and nothing else of yours does.
  Bare `@share` stays in every feed. Today `@share(…)` is read as `@share`.
- **Calendar feeds, both ways.** Feed events are read-only; a key on one
  (in the calendar view) could copy it into `calendar.zortex` as your own
  line, to plan around or link a project. `:ZortexIcalImport` already
  copies a whole file once.
- **Recurring project tasks** (`@repeat(weekly)` on a project task, like
  calendar entries) and **task dependencies** (`@depends(id)`, already in the
  task schema but unused).

## 4. Search

- **Search inside a folder:** a `z/` or `dir:z/projects` prefix, or a picker
  scope, limiting `services/search` to notes under a directory.
- **Tag words in search:** `@tag` narrowing results to sections or lines
  with that tag.

## 5. Editing and maintenance

Renaming with link rewriting (`:ZortexRename`), broken-link diagnostics
and backlinks of the section under the cursor (`:ZortexBacklinks`, in the
quickfix list) are done. Left:

- **Backlinks panel:** a side window that follows the cursor, instead of a
  quickfix list on request.
- **Archive revert:** moving an archived section back from
  `z/archive.*.zortex` (the stub was removed; `u` right after archiving is
  the only undo today).

## 6. The web app

### Goal

A small, read-mostly web app for the notes, deployed as a **NixOS service on
a Raspberry Pi 4** that already runs other servers. It reads a **synced
zortex directory** (Syncthing) and must work **without Neovim**.
The important features are:

1. **Note search** with the same ordered-path matching and ranking as the
   plugin.
2. **Directory navigation and search**, especially `z/*` (folders, note
   titles and aliases, tags, archived notes marked).
3. **Rendering Zortex files** faithfully: structure, tasks, attributes,
   links that work, tables, code, math, footnotes.

Editing started as a non-goal; `-writable` now covers line-level edits
(tasks, text, moving lines) and the inbox, and nothing more.

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
  `.stfolder`). Write into the synced folder only what the server alone
  writes: line edits with `-writable` (checked against what the page saw),
  `z/feeds/` and `.z/time_spent.json`. Its own state (search history,
  caches, posted XP) lives in the service's state directory, so it can't
  conflict with Neovim's files.

### Recommended shape

- **Language: Go.** A single static binary, small resident memory, a mature
  standard library for HTTP and file watching, and simple Nix packaging
  (`buildGoModule`). Rust would also fit; Python is the easiest to write but the
  heaviest at runtime.
- **Grammar: decided — hand-port `core/syntax` to Go** and validate it
  against the conformance fixtures (option A below). A tree-sitter grammar
  is wanted later (section 7).
- **What else to port (smallest first):**
  - header and notes index (names, aliases, tags, archived), from
    `core/notes`
  - the section tree, from `core/section` (sections are already in the
    syntax output)
  - **link resolution**, from `core/link`: article-or-tag, prefix
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
- **Routes** (as built; the full list is in
  [Web.md](Web.md#pages)): `/` home, `/f/<dir>` folders and
  files, `/n/<rel>` a rendered note with its outline and backlinks,
  `/search?q=` results as breadcrumbs then matching lines, and JSON under
  `/api/` (`/api/search`, `/api/note`, `/api/resolve`, …).
- **With the domain ported:** project progress (`/projects`), KR progress
  (`/okr`), the calendar on the home page and the weekly review
  (`/review`) are built; the area overview (section 2) is left. The JSON
  shapes are defined by `zortex.query` (`projects()`, `objectives()`,
  `agenda()`, `review()`), so the plugin and the app share fixtures for
  those too.

### Grammar options

The parser is only part of what the app needs: the link resolver, search and
the notes index have to exist in Go too. So the real choice is how much of
the core gets two implementations.

| option | one source of truth? | runtime | cost | notes |
|---|---|---|---|---|
| **A. Hand port to Go + fixtures** | no, but drift is caught by `tests/fixtures/ast` | fastest; pure Go, `CGO_ENABLED=0` | ~700 lines for the grammar; resolver and search later, each with its own fixtures | Simplest to reason about. Recommended for the grammar. |
| **B. Shared rule file** (patterns read by both) | lexical rules only | fast | a rule format plus two small interpreters | Lua patterns and Go RE2 are different languages (Lua has no alternation, RE2 has no `%b()` balance or frontier patterns), so the file needs its own subset translated to both. It only covers tokens, not the stateful parts (header, fences, levels, "a task is not a label"), which stay code in each language. Little gain over A. |
| **C. Run `core/syntax.lua` in Go** with gopher-lua (a pure-Go Lua 5.1) | yes, for the grammar | slower than native Go; fine with incremental re-parse on file change | small; the grammar already runs with only the Lua standard library (`test_syntax` checks this) | Measure on the Pi. Extending this to the resolver and search would mean moving their `vim.*` calls (files, JSON, time) behind a small host interface. |
| **D. Go core, Neovim as a client** | yes, for everything | Go speed everywhere | large: the plugin keeps highlighting and editing in Lua but asks a `zortex` binary (a long-running job over stdio or msgpack-RPC) for parse, resolve, search and index | One implementation for the plugin and the app (`zortex serve`). The plugin then needs a binary: Nix, `go install`, or release builds. |
| **E. Tree-sitter grammar** | yes, for the grammar | fast, incremental | large: `grammar.js` plus a C external scanner for the context-sensitive parts | Neovim gets native highlighting, folding and language injection in code blocks; Go uses it through cgo bindings. Section levels, the resolver and search still have to be written per language. |

**Suggested path:** start with **A** for the grammar, since the fixtures
already exist and pure Go keeps cross-compiling for the Pi trivial. Reuse the
same approach for the resolver and search with generated fixtures. If keeping
two resolvers in sync becomes the main cost, **D** is the natural next step;
**C** is a cheap experiment to run first if you'd rather not port at all.

### Nix

Built as the flake's `packages.<system>.default` (the `zortex` binary) and
`nixosModules.default`, which defines `services.zortex`: one
`zortex-web` systemd unit with `notesDir`, `dataDir` (its `StateDirectory`),
`web.address` / `web.port` / `web.basePath`, `web.memoryLimit`,
`web.writable` (read-only access to the notes otherwise), `web.authFile`,
the `ntfy.*` settings and `extraArgs`. [Server.md](Server.md) has the
setup, behind a reverse proxy with a login or on Tailscale only; Syncthing
keeps the notes folder in step, and the app polls it (no inotify needed).

### Phases

1. **Grammar — done:** `app/syntax` (Go port of `core/syntax`) passes every
   conformance fixture, including `edge.zortex` (hand-picked corner cases)
   and `random.zortex` (600 lines of shuffled syntax fragments). `zortex
   parse` / `zortex sections` expose it; `nix/zortex.nix` builds it.
2. **Index and navigation — done:** `zortex serve` (`app/web`): rendered
   notes, file browser and viewer, rescans on a timer (polling instead of
   fsnotify: no dependency, and it works the same on Syncthing folders),
   `services.zortex.web` in the NixOS module. See [app/README](../app/README.md).
3. **Links and search — done:** `app/notes`, `app/links` and `app/search`
   agree with the plugin on `tests/fixtures/resolve.json` (73 links) and
   `search.json` (31 prompts); the web app resolves links while rendering,
   shows backlinks, broken links and tags, and has a live search page with
   the section, article and text modes and its own search history (in
   `-data`, apart from Neovim's own).
4. **Domain views — partly done:** the home page has the calendar (with
   notifications), the pomodoro, timers, alarms and a stopwatch, time
   tracking, season XP and the Structure check; notes can be edited
   (`-writable`) and update live. Project pages (`/projects`, `/project`)
   show progress, the key results a project moves, its log and calendar
   history; `/okr` the objectives against their period and `/review` the
   weekly review. Still to do: the area overview.

## 7. Tree-sitter grammar

A `tree-sitter-zortex` grammar, once the Go port and the conformance
fixtures have settled the grammar's details.

- **Why:** Neovim gets native highlighting, folding, text objects and
  language injection in code blocks (and in `$math$`), with incremental
  parsing; the Go app can use the same grammar through its bindings; other
  editors come for free.
- **Why later:** the context-sensitive parts are easy to get subtly wrong in
  tree-sitter: the header block, labels nesting by indentation, matching
  code fences, `$$` blocks, "a task is never a label", list items with keys
  and checkboxes. These need a C external scanner. The AST fixtures
  (`tests/fixtures/ast`) are the acceptance test: the tree-sitter tree,
  mapped to the same line kinds and spans, must agree with them.
- **Scope:** grammar (`grammar.js` + `src/scanner.c`), highlight and fold
  queries mirroring `features/highlights.lua` groups, injections for fenced
  code. Section levels, the link resolver and search stay in Lua/Go.

## 8. Agreed on 2026-10-16

From a review of open ideas. All of it shipped in 0.1.0 (see
[CHANGELOG.md](../CHANGELOG.md)); the notes say what was decided and why.

### Events and notifications

Notifications stay on for every timed line: they keep the day on track
and pull you out of deep focus at the end of a block. `@n(no)` opts a line
out. `@event` marks what you plan *around* rather than what you planned (an
appointment, a flight); today it decides the web month grid's dot, and it is
the hook for anything that should treat fixed time differently later (the
capacity line counting it as busy, a different icon).

### Inbox triage

- `@project(1.4)` on an inbox item or a loose task says where it belongs
  (a project link, as `@a(…)` is an area link).
- The daily review lists inbox items and tasks carrying `@project` with `m`:
  move the line under that project, and drop the attribute.
- `review.inbox_default` (config) is where `m` puts an item without
  `@project`: for example a heading under `[P/#Areas]`, a copy of the area
  tree in the projects note that holds maintenance tasks and notes too small
  to be projects.
- The planner lists the inbox last (done); `p` puts a line on the day.

### Links

- A `-` component also matches a task's `@id`: `[P/-aB3x9]`. Task links
  then survive renames without a new component.
- A note outside `notes_dir` (a repository's `doc/Roadmap.zortex`) resolves
  its links in its own folder (the folder, or the nearest one above with a
  `.z/`), and `[~/P/#Subaru]` reaches `notes_dir`, the way `/` reaches the
  note itself and `./` the parent line. A sigil rather than a word like
  `ZORTEX/` can't clash with an article name.

### Tags

- **`is:` filters** in tag searches: a colon can't be part of a tag, so
  `is:` words are unambiguous, and they compose with the all-of words and
  any-of commas already there: `@[rust is:heading]`, `@[rl is:open]`,
  `@[rust is:task, rust is:label]`. Kinds: `heading`, `label`, `item`,
  `task`, `open`, `done`, `resource`. The `@[#-:/tags]` form considered
  first collides with the scope, which is written as a link
  (`@[R/#Rust/async]`).
- **Broken and orphan tags**, computed on request (the web app's `/broken`,
  `:ZortexBrokenLinks` in Neovim), listed apart from broken links:
  tag searches that find nothing, `[@Tag]` links to a header tag no note
  has, and bare tags no tag search uses. Bare attributes (`@p1`, `@sm`,
  `@2h`) are not tags.
- Kept as they are: the rows of a tagged heading that isn't a resource, and
  Structure and tags as separate things.

### Labels

Most labels are one to three words, and a sentence that happens to end in a
colon shouldn't open a section. So a plain `Text:` is a label only up to
three words; a longer one opts in with `*A longer label like this one:*`,
parsed at the same level as plain labels. Both parsers (Lua `core/syntax`,
Go `app/syntax`) and `tests/fixtures/ast` change together. Before the
switch: a command that lists the lines whose kind would change (they stop
being `[:Label]` link targets), and a check that `*…:*` doesn't collide with
an emphasis span.

### Web

- **Hover cards** on links: for a note, its title, path, header tags, first
  lines and backlink count; for an image, a thumbnail; for an external link,
  its domain and URL only (the server fetches nothing).
- **Graph:** under each note, the headings of it that other notes link to.
  The structure the notes actually grow, rather than every heading.

### XP

Behaviour stays. Two additions: `xp.area_split` sets a geometric ratio for
splitting an award between areas (default 0.5; 1 even, 0.7 gently
decaying; it replaced the harmonic split), and the wording: XP is estimated
work, so say "10 XP = 1 hour of estimated work" wherever XP is shown or
documented, with hours next to XP.

### Help

One table of every zortex buffer's and picker's keys
(`lua/zortex/keys.lua`) is read by `?`, the README, `:help zortex-keys` and
the picker titles, which also name each picker backend's own help key;
`:help zortex` works for local installs.

### Dropped

A raw-text section, uploading a file to render it, generating tags from
Structure, XP "overlap", and changes to the calendar picker.

## 9. Agreed on 2026-10-22

From a pre-release review. All of it is in 0.1.0 (see
[CHANGELOG.md](../CHANGELOG.md)); the notes say what was decided and why.

### Links with display text

`[the plan](P/#1.4)` is a zortex link shown as its text. Markdown's form
won because people coming from Markdown already write it, the importer can
keep link text, and it reads well unrendered. What is in the parentheses
decides: a URL (a scheme, `www.`) or a file (a path, or a name with an
extension) stays a Markdown link; a typed component (`#`, `:`, `*`, `-`,
`%`, `>`, `@`) or a bare name is a zortex link. A rename rewrites only the
definition. `![alt](./pic.png)` is the image form. Considered and left
out: `[P/#1.4|the plan]` (the `|` breaks table rows) and reference links
`[the plan][p14]` with a definitions block (more to maintain per note).
A definition with `)` can't use the form; such links stay `[…]`.

### Repeating entries: @from and @to

`@from(date)` and `@to(date)` bound a `# Repeating` rule (the first day is
what every n counts from), instead of `@since` and `@until`: the same
words as a calendar line's times, so a rule can carry both
(`@from(07:30) @to(08:15) @from(2026-10-17)`): a date is a bound, a time is
the entry's time. The old names are still read until the vault check can
point at them.

### Sync conflicts

Two devices must never write the same synced file. So `.z/` holds only
what every device shares and that changes rarely (seasons, the last daily
review), written only when it changes, with conflict copies merged when it
loads; what each Neovim writes often (the link index, search history,
levels announced, notification bookkeeping, the log) lives in
`stdpath("state")/zortex`; and the XP summary for the web app is one file
per device (`.z/xp_summary.<device>.json`, the server shows the newest).

### Reports say only what is wrong

`/broken` and the weekly review list a kind of problem only when there is
one: no "every link resolves" per kind, no `0 broken links`. One line says
nothing is broken when nothing is.
