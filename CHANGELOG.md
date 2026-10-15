# Changelog

All notable changes to zortex.nvim and `zortex serve`. The project follows
[semantic versioning](https://semver.org): until 1.0 a minor version may
change the note format or the configuration.

## [0.1.0] - unreleased

The first public release.

### Neovim plugin

- Task copies: a project task put on the calendar keeps its `@id`, and lines
  with the same `@id` are one task: checked when any copy is, XP paid once
  by the project, toggling one toggles the others, `@spent` adds up. A
  calendar line without a checkbox that links a task stands for it; a
  checkbox line that links a task takes its `@id` when toggled.
- `@[rust async]` (all of the tags) and `@[rust, rl]` (any); quotes `> `,
  bullets `-`.
- `[./-Item]` links continue the link of the line they're nested under
  (`09:00 [P/#1.4 - zortex]` / `  - [ ] [./-Improve website]`).
- The planner lists projects with their tasks under a heading each, then
  key results, to-dos and areas, and puts tasks on the day as copies (`p`, under their project's
  block), projects as blocks with their open tasks (`P`), and carries the open
  tasks of the days before to today, marking the old lines `[>]`
  (`:ZortexCarryForward`, `ui.planner.carry_forward`).

- One grammar (`core/syntax`) for every feature, documented in
  [doc/Syntax.md](doc/Syntax.md) and checked against the parser by a test.
- Structural search, links with completion and preview, backlinks and broken
  links from a persistent link index. A note's file name is one more alias
  of its articles in every search mode (`okr` finds `@@Objectives`).
- Plain text search (`:ZortexSearchText`, `<leader>z/`): the prompt as typed,
  smart case, over every line; `<M-t>` cycles section, article and text mode.
- Key prefixes are named in which-key when it is installed (`<leader>z`
  "Zortex", `<leader>zC` "Calendar & digest", ...; `keymaps.groups`).
- Projects, areas, objectives and key results as entities with progress,
  a weekly review, a day planner, a calendar view with iCal import/export.
- XP read off completed tasks, calibrated in hours: `@size` is estimated
  time (`xp.sizes`), 10 XP an hour. Mastery (area XP) follows the plan: work
  on a project a key result links counts in full, to the objective's areas
  first; key results reached and objectives done add a completion bonus.
  `:ZortexXPGuide` shows the calibration from your config.
- Seasons are progress on their objectives (weighted by objective XP), with
  tiers at 25/50/70/85/100%; with no season started by hand, the season is
  the calendar quarter. A mastery tree shows both.
- The day planner ranks key-result work first, the further behind schedule
  the higher; a daily review (`:ZortexReview day`) next to the weekly one,
  both opening with what is left in the inbox, then objectives, XP on key
  results and time spent.
- [doc/Planning.md](doc/Planning.md) explains the plan, the loop and XP.
- First run: a new notes folder gets calendar, projects, areas, okr,
  structure and inbox notes from short templates (`:ZortexInit` later).
- `:checkhealth zortex`: Neovim version, the notes folder, key notes, broken
  links, sync conflict copies, the ntfy topic, optional integrations.
- Conflict copies from Syncthing (`note.sync-conflict-….zortex`), Dropbox
  and Nextcloud (`note (… conflicted copy …).zortex`) are not notes, in
  Neovim and on the web, so a copy of `projects.zortex` doesn't double
  every project.
- `:help zortex`, generated from the actions and the configuration defaults.
- Pickers on snacks.picker, telescope or fzf-lua, with the same keys and
  previews on each (`ui.picker = "auto"` follows LazyVim's choice), and
  `vim.ui.select` without any. Link completion for blink.cmp and nvim-cmp,
  registered and listed for zortex buffers by itself. CI runs both against
  the real plugins (`tests/plugins.sh`).
- Links to links: a `>` component (`[R/#Rust/>The Rust Book]`) opens the link
  it matches instead of the line it is on, with a picker when several match
  and completion after `>`; its preview shows the link's line and the notes
  nested under it. The picker shows every match with its title, target and
  section and a preview; `<C-l>` goes to the link's line.
- Tag searches take a scope: `@[R/#Rust/async]`, `@[@Library/rl ai-model]`,
  `@[*/rust]`; a tag on a heading tags its section. `-` finds a list item by
  its markdown link's text (`[R/#Rust/-The Rust Book]`).
- Bare `@words` are tags on any line (`@rust`, `@home`, `@ai-model`); items
  list them as `attributes.tags`.
- Tags are highlighted on every line (text and quotes too), and the `@` of
  `@[...]` is dimmed (`ZortexTagSearchAt`).
- Resources and their notes: a heading that is only a link and attributes is
  a resource, its section notes about it; notes (that, and lines nested
  under an item holding a link) match tag searches only by their own tags.
- Tag completion: after a bare `@` and inside `@[...]`, the tags your notes
  use, most used first, with how many lines use each.
- `:ZortexLinkOpenWeb` (`<leader>zgX`) opens the link under the cursor in the
  web app (a zortex link, tag search, file, or the line itself), in the tab
  you focused last on this computer when there is one
  (`features.web.reuse_tab`). `gx` on a tag index's label opens the index.

### Server (`zortex serve`)

- Tag indexes: a label whose lines are all `@[...]` searches (or items
  grouping them) shows as rows of chips with counts over one shared table;
  the chosen chip is in the address (`#tags=R/rl`). `@[...]` shows like a
  link (a dim `@`, no brackets).
- `POST /api/open` shows a page in the tab focused last on the same device
  (for Neovim's `:ZortexLinkOpenWeb`).
- Tag tables show a row's notes: up to three lines under the item, longer
  notes in a panel with the note they link to. A heading that is only a
  link (`### [Book](https://…) @rust`) is a row, and its section its notes;
  labels indented under an item stay in its notes. A `- Key: text` item no
  longer shows its key twice.
- Rendered notes, search, file browser, tags, broken links, the notes not
  linked from Structure; live updates while you edit elsewhere. The file
  browser lists every file and hides notes with generated names
  (`2026-10-15.042.zortex`) until "show all".
- `>` links go straight to the link they match, or to a page listing them.
- `@[...]` tag searches list the tagged lines they find.
- Home page: today's calendar, the pomodoro (shared with Neovim), timers,
  alarms and a stopwatch, time tracking on tasks (`@spent`), the season's objectives and Mastery XP.
- Calendar notifications, pomodoro changes, timers and alarms through ntfy.
- `-writable`: check off tasks, edit, add, move and delete lines, add to the
  inbox, from any browser.
- `-html-scripts`: HTML files in the notes may run JavaScript, sandboxed in
  an opaque origin (off by default).
- `GET /api/digest`: the coming days of the calendar for any mail service.
- Slides: any note as a slide deck (`?view=slides`, `:ZortexPresent`), cut at
  its headings (`@slides(n)` to choose the level), with speaker notes
  (`Notes:`), step-by-step reveal (`@step`, `@steps`), a presenter window,
  an overview, live redraw and one page per slide when printed.
- Math (`$…$`, `$$…$$`, `$$` blocks) typeset with KaTeX; `![./pic.png]`
  shows the image, `![./clip.mp4]` the video.
- Markdown files (`.md`, `.markdown`) render in the file viewer like a note,
  math included; HTML and Markdown files have a "source" link to their text.
- Task copies on the web: toggling a calendar copy toggles its project task
  (and the other way round), calendar lines that link a task show and toggle
  it, a project task done through its copy shows done, the clocks count
  against the first open task of the running calendar block, a **Carry**
  button (`POST /api/calendar/carry`) brings open tasks to today, and
  `/broken` lists ids that don't line up.
- `/resources` lists every resource by default (`?show=unlinked` for the
  unlinked ones; `/api/resources` still defaults to unlinked).
- Tag tables: `!@[scope/tags]` shows a tag search as a sortable, filterable
  table (item, link and its kind, tags, one column per `@key(value)`,
  where, nested notes); `@[…]` link pages show the same table.
- A note's `# Structure` section lists its sub-notes: they count as in the
  structure, and the hub owns its part of the tree.
- Connections on every note page (structure parents and children, links
  each way) and `/graph`, the whole structure as a card per section, with
  the tags beside it and a filter for notes and tags.
- An optional login (`-auth-file`, `ZORTEX_AUTH`) for setups without a proxy
  that has one; a warning when listening beyond localhost without a login.
- Released as binaries for Linux and macOS and as
  `ghcr.io/t-wilkinson/zortex`; a NixOS module.
