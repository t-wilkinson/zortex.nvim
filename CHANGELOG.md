# Changelog

All notable changes to zortex.nvim and `zortex serve`. The project follows
[semantic versioning](https://semver.org): until 1.0 a minor version may
change the note format or the configuration.

## [0.1.0] - unreleased

The first public release: a Neovim plugin and a server (`zortex serve`)
that share one folder of plain-text notes.

### Notes

- One note format, `.zortex`: a header (`@@Name`, aliases, `@Tags`),
  headings, bold headings (`**Text:**`), labels (`Ideas:`, up to three
  words; `*A longer label:*` beyond), lists, tasks, timed calendar lines
  (`14:00 event`, `16:00 [ ] task`), attributes, tags, links, math, code,
  tables, quotes and `---` rules. One grammar parses it for every feature,
  in Lua and in Go, checked against shared fixtures and against the
  reference in [doc/Syntax.md](doc/Syntax.md).
- Attributes have a full form and a short one: `@area(4.1)` / `@a(4.1)`,
  `@notify(15)` / `@n(15)`, `@size(sm)` / `@sm`, `@dur(90m)` / `@90m`.
- Links name structure, not ids: `[Sourdough/#Method]`, `[P/#1.4]`,
  `[A/#1.2/:Fitness]`, `[/#Local heading]`, `[./-Item]` (continuing the
  link above), `[R/#Rust/>The Rust Book]` (a link to a link), `[P/-aB3x9]`
  (a task by its `@id`). Matching is by prefix, case-insensitive.
  A list item matches by its text with its links' brackets left out:
  `[P/-To this link]` finds `- To [this link]` and `- To [this link](./x)`.
  `[the plan](P/#1.4)` is the same link shown as its text (Markdown's form,
  so imported notes keep their link text; a rename rewrites only the part
  in parentheses); URLs and files in parentheses stay Markdown links.
  `![alt](./pic.png)` is an image with alt text.
- Tags and tag searches: bare `@words` on any line, `@[rust async]` (all),
  `@[rust, rl]` (any), scopes (`@[R/#Rust/async]`), `is:` words, and
  `!@[…]` tables in place. Attributes are searchable as `key(value)`:
  `@ref(Smith & Lee, 2020)` is found by `@[author(Smith)]`,
  `@[author(Smith & Lee)]` and `@[year(2020)]`.
- Footnotes take any text but `]`: `[^Smith, 2020]` cites the
  `[^Smith, 2020]: …` line at the bottom of the note (the web app shows
  it as `(Smith, 2020)` with the reference as its tooltip).
- What counts as a label is configurable: `syntax.label_max_words`
  (shared with the server through `.z/syntax.json`) and, in Neovim,
  `syntax.is_label`.
- `:ZortexImportMarkdown [path] [--join]` turns Markdown files, or an
  Obsidian vault, into notes beside them.

### Neovim

- Structural search (`:ZortexSearch`): words match a section's path in
  order, and a line's path is its section's and then the line; ranked by
  hierarchy and by what you open; `<M-n>` narrows to a section (every line
  in it, no cap); article and plain-text modes. Pickers on snacks.picker,
  telescope, fzf-lua or `vim.ui.select`.
- Links: follow, preview, open in the web app, complete while typing (with
  tags and area values), backlinks, broken links and tags that go nowhere
  (quickfix and diagnostics), from a persistent link index.
- Editing across notes: `:ZortexMove` moves a section or lines anywhere,
  or renames a heading or label (`:ZortexMove New title`), as `mv` does
  files, and rewrites the links that would stop finding it, asking first
  when they are in other notes. `:ZortexUndo` takes it back in every note
  it changed. A note changed on disk is never edited blind.
- Highlighting, concealing and folding for the whole format (`@fold`
  keeps a section closed), `J` that joins lines the way they read, a table
  of contents that follows the note as you edit, link parts read as
  `P › #1.4` (the separator's character and colour are yours:
  `ui.highlights.link_separator`, `ZortexLinkDelimiter`), and slides
  (`:ZortexPresent`).
- Projects, areas, objectives and key results as entities with progress.
  Objectives are `## 3M-2026-Q4 Title` headings, grouped under top-level
  headings; key results are `- KRn:` items whose linked projects drive
  their progress. Organizational headings group projects without being
  one; tasks nested under a task share its `@size`.
- The calendar note: days as `**YYYY-MM-DD:**`, timed entries and tasks,
  `# Templates` for new days (`## Daily`, `## Weekday`, `## Sunday`, …)
  and `# Repeating` for entries that recur (`@repeat(…)` how often, `@on(…)`
  which days, including `2nd tue` and `last fri`, `@at(…)` what time,
  bounded by `@from(date)` and `@to(date)`, birthdays with `@born`, which
  reads `1990`, `1961-07-02`, `07-02`, `07-02-1961`, `Feb 1` and
  `February 1, 2000`, and repeats yearly on the day it names); days
  grouped under a heading per month (`# October 2026`, made as new days
  need them, other months folded; `:ZortexCalendarGroup` moves older days
  in); breaks inside a block (`12:00 Break @15m` after `10:00 Study`, or
  nested under it) hand the block back when they end, with a "Back to
  Study" notification and the time tracking following it; the
  planner writes a day's repeating tasks into it; a month view whose
  "Coming up" lists events, `:ZortexToday`, `:ZortexNow` and
  `:ZortexTimeShift`; notifications for timed lines, and for all-day lines
  at `notifications.all_day_time`; other calendars' events, read-only.
- The planner, the reviews and the lines they write (focus projects,
  calendar copies, a project linked to a key result) use links as
  written: `[P/#1 Programming/#1.4 - zortex]`, `[./-Improve website]`
  (a key result's text follows its link). Calendar
  notifications read links as their text. The plan lists up to
  `ui.planner.max_tasks` project tasks (30) and `max_todos` to-dos (10).
- A day planner that ranks the week's focus and key-result work first,
  carries open tasks forward and weighs the day against its free time; a
  daily and a weekly review written in `reviews.zortex` (from its own
  `# Templates`), read top down from the vision, with each fix one key away.
- Sync conflict copies of notes are left out of the notes and merged in a
  diff with `:ZortexConflicts`.
- Task copies: lines sharing an `@id` (a project task and its calendar
  copy) are one task, ticked together.
- XP that follows the plan: 10 XP is an hour of estimated work (`@size`),
  counted twice and kept apart: area XP (Mastery: all of every piece of
  work's XP for the areas it serves, `xp.area_transfer`; work with no area
  earns for `@a(0.1)`, `xp.default_area`) and season XP (only work a key
  result links, `xp.season_transfer`, plus the key-result and objective
  bonuses), with seasons whose tiers are measured on their objectives.
  `@p` and `@i` rank work; they multiply XP only when `xp.modifiers` says
  so (1 by default). The old `xp.alignment` shares are gone
  (`:checkhealth` warns).
- The daily review lists work finished without an area (`A` gives it one,
  on its project's heading or the task) and writes `@a(0.1)` on the rest
  when it closes (`review.default_area_on_close`).
- `:Zortex attributes` lists every attribute and how it is written, and a
  bare `@` completes them, each with its format as documentation.
- Sizes show what they're worth as you type them (`@sm ≈ 30m · 5 XP`,
  `features.size_hint`), and `@size(` and `@s…` complete the sizes with
  their hours and XP.
- `:ZortexOpenWeb` opens the note, at the cursor's section, in the web app.
- The planner keeps a task's links' names in its text (`Read [./doc-1]` and
  `Read [./doc-2]` no longer both read `Read`), and links tasks that would
  link the same by their `@id`.
  `:ZortexSeason start [span] [name]` starts one (`Season 10 Juniper`, the
  word moving on with the number) and adds its heading to the OKR note.
  `xp.enabled = false` turns XP off.
- `:Zortex` keeps the notes in order: `init` creates the missing key notes
  from short templates, `reindex` rebuilds the link index, `refold`
  recomputes folds, and `help` lists every command and key with your
  prefixes. `setup()` writes nothing; it says when key notes are missing.
- Notifications and the pomodoro are the server's: saving the calendar
  sends its timed lines (`:ZortexNotifications sync|list|send`),
  `:ZortexPomodoro` drives the server's clock, and what the server
  announces shows in Neovim (`notifications.alerts`).
- Every action is a command, a key under `keymaps.prefix` and an API
  function, generated from one list; `:help zortex` and the README tables
  are generated from it and from the configuration defaults. which-key
  names the key groups when installed.
- `require("zortex")` exposes the services and `zortex.query`, the whole
  model as plain data; `:ZortexExport` writes it as JSON.
- Safe to sync: `.z/` in the notes folder holds only what devices share
  and rarely change (XP seasons, the last daily review) plus one XP summary
  per device (`xp_summary.<device>.json`). Caches, search history and what
  was announced stay on each machine (`stdpath("state")/zortex`), files are
  rewritten only when their content changes, and a sync tool's conflict
  copy of the seasons is merged and removed.
- Needs Neovim 0.10 or newer and nothing else; `:checkhealth zortex`
  checks the setup and whether the server answers.

### Server (`zortex serve`)

- One Go binary (releases for Linux and macOS, `ghcr.io/t-wilkinson/zortex`,
  a NixOS module) that reads the notes folder: rendered notes with working
  links and hover cards, search, backlinks, tags and tag tables, broken
  links and the notes nothing reaches (`/broken` lists only what has a
  problem, and leaves the top bar when nothing does), `/graph` (cards
  for the structure; a long one spreads over more columns), and a file
  browser whose resource folders list their files and what links them.
- The folder is watched (inotify, on Linux), so a synced edit shows within
  about a second; `-poll` still rescans as a safety net.
- The top bar's Files menu lists the `z/` folders and your named notes;
  the footer links the pages the top bar doesn't.
- A JSON API: every page's data at `/api` + its path
  (`/api/projects`, `/api/review?day=today`), notes at `/api/n/<path>`,
  snake_case keys, `{"error"}` on failure and `{"ok": true}` from writes.
- A home page with today's calendar, an inbox box (offline too, in the
  installed app), the pomodoro, timers, alarms, a stopwatch, time tracking
  on the task you're working on (`@spent`), the week's focus and XP.
- `/projects`, `/project`, `/okr` (objectives against the time passed, each
  season's name and tier, key results nothing can move), `/areas` (every
  area with its XP, level, objectives and projects, and the area XP of all
  of them) and `/attributes`.
- The daily and weekly reviews on the web (`/review?day=today`, `/review`),
  with their fixes under `-writable`: tick, tomorrow, due, move inbox lines
  to a project, give finished work an area, pick the week's focus, write
  the entry in `reviews.zortex`, and finish the daily review (shared with
  Neovim through `.z/review_state.json`).
- The web editor offers the common attributes as chips; the inbox box adds
  a note by default.
- Calendar notifications, pomodoro phases, timers and alarms through ntfy,
  and to Neovim (`GET /api/alerts`).
- `-writable`: tick, edit, add, move and delete lines from any browser,
  checked against what the page saw.
- Calendar feeds (`-feeds`): other calendars fetched into
  `z/feeds/<name>.zortex`; `/calendar.ics` publishes your `@share` lines.
- Slides with speaker notes and step-by-step reveal, math with KaTeX,
  images and video in place, Markdown and sandboxed HTML in the file
  viewer.
- An optional login (`-auth-file`), an API key for Neovim (`-api-key`),
  and `-xp=false` to hide XP.
- Installs as an app (PWA); the last pages you opened read offline.

### Project

- Documentation: the README's quickstart, `:help zortex`, the syntax
  reference, an example notes folder ([doc/example](doc/example)), the
  website and server guides ([doc/Web.md](doc/Web.md),
  [doc/Server.md](doc/Server.md)), planning and XP
  ([doc/Planning.md](doc/Planning.md)) and the architecture.
- CI on every push: the Lua tests on Neovim 0.10, stable and nightly (and
  against snacks.nvim, telescope, fzf-lua and blink.cmp), `go test -race`,
  `gofmt`, and a check that generated docs and fixtures are up to date.
- MIT license.
