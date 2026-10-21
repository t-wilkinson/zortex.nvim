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
- Tags and tag searches: bare `@words` on any line, `@[rust async]` (all),
  `@[rust, rl]` (any), scopes (`@[R/#Rust/async]`), `is:` words, and
  `!@[…]` tables in place.
- `:ZortexImportMarkdown [path] [--join]` turns Markdown files, or an
  Obsidian vault, into notes beside them.

### Neovim

- Structural search (`:ZortexSearch`): words match a section's path in
  order, ranked by hierarchy and by what you open; article and plain-text
  modes. Pickers on snacks.picker, telescope, fzf-lua or `vim.ui.select`.
- Links: follow, preview, open in the web app, complete while typing (with
  tags and area values), backlinks, broken links and tags that go nowhere
  (quickfix and diagnostics), from a persistent link index.
- Editing across notes: `:ZortexRename` rewrites every link through a
  heading or label, `:ZortexMove` moves a section or lines anywhere, and
  `:ZortexUndo` takes either back in every note it changed. A note changed
  on disk is never edited blind.
- Highlighting, concealing and folding for the whole format (`@fold`
  keeps a section closed), `J` that joins lines the way they read, a table
  of contents and slides (`:ZortexPresent`).
- Projects, areas, objectives and key results as entities with progress.
  Objectives are `## 3M-2026-Q4 Title` headings, grouped under top-level
  headings; key results are `- KRn:` items whose linked projects drive
  their progress. Organizational headings group projects without being
  one; tasks nested under a task share its `@size`.
- The calendar note: days as `**YYYY-MM-DD:**`, timed entries and tasks,
  `# Templates` for new days and `# Repeating` for entries that recur
  (`@repeat(…)`, birthdays with `@born`); a month view, `:ZortexToday`,
  `:ZortexNow` and `:ZortexTimeShift`; other calendars' events, read-only.
- A day planner that ranks the week's focus and key-result work first,
  carries open tasks forward and weighs the day against its free time; a
  daily and a weekly review written in `reviews.zortex`, read top down from
  the vision, with each fix one key away.
- Task copies: lines sharing an `@id` (a project task and its calendar
  copy) are one task, ticked together.
- XP that follows the plan: 10 XP is an hour of estimated work (`@size`),
  Mastery per area, and seasons with tiers measured on their objectives.
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
- Needs Neovim 0.10 or newer and nothing else; `:checkhealth zortex`
  checks the setup and whether the server answers.

### Server (`zortex serve`)

- One Go binary (releases for Linux and macOS, `ghcr.io/t-wilkinson/zortex`,
  a NixOS module) that reads the notes folder: rendered notes with working
  links and hover cards, search, backlinks, tags and tag tables, broken
  links and the notes nothing reaches, `/graph`, and a file browser whose
  resource folders list their files and what links them.
- A home page with today's calendar, an inbox box (offline too, in the
  installed app), the pomodoro, timers, alarms, a stopwatch, time tracking
  on the task you're working on (`@spent`), the week's focus and XP.
- `/projects`, `/project`, `/okr` (objectives against the time passed, each
  season's name and tier, key results nothing can move) and `/review`.
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
