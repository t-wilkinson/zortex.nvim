# Changelog

All notable changes to zortex.nvim and `zortex serve`. The project follows
[semantic versioning](https://semver.org): until 1.0 a minor version may
change the note format or the configuration.

## [0.1.0] - unreleased

The first public release.

### Neovim plugin

- `J` in a note joins lines the way they read: the joined line's `#`s,
  `-` (with its `[ ]`), `1.` or `> ` go, and so does the `:` of a label or
  bold heading it is joined onto (`Fitness:` + `- run 5k` is
  `Fitness run 5k`). Counts, visual mode, `.` and undo work as with Vim's
  `J`; code blocks and `gJ` join as written (`features.join`).
- Edits across notes can be taken back: a rename, `:ZortexMove` and an
  inbox move (`m`) load the notes that aren't open, change and save them,
  and `:ZortexUndo` (`<leader>zU`, or `u` in the review) undoes the whole
  thing in every note. A rename that changes other notes says what it will
  change and asks first (Rename / List / Cancel).
- Neovim no longer edits a note blind when it changed on disk (the web app,
  a phone): an edit is checked against what was read, and refused when the
  lines around it differ; an open, unsaved buffer is reloaded first.
- **Other calendars in yours.** The events the server fetches from
  calendar feeds (`z/feeds/<name>.zortex`) show in the calendar view, the
  planner (the day's under "From your calendar feeds", and in "Coming up"),
  the agenda and the calendar picker, read-only and labelled `· <feed>`;
  they count as busy in the capacity line unless marked `@free`, and notify
  unless `@n(no)` (the server writes that by default).
  `features.calendar_feeds = { cozi = false }` hides one feed, `false` all
  of them. `@share` and `@free` are attributes, not tags.
- The calendar view no longer marks a day as notifying for a line with
  `@n(no)`.
- `:ZortexToday [date]` (`<leader>zd`) goes to today in the calendar,
  adding the day from its template (`ui.planner.templates`) when it isn't
  there yet.
- **A day of the calendar is a bold label**, `**2026-10-21:**`: new days
  get it (the planner, carrying tasks, `add_entry`, the web app's Carry),
  and a plain `2026-10-21:` still reads the same, in Neovim and on the web.
  So an `Outcomes:` label nests under the day: the two or three results
  that would make it a success. Change existing days by hand if you like:
  `:%s/^\(\d\{4}-\d\d-\d\d\):$/**\1:**/` in `calendar.zortex`.
- **The weekly review reads top down**: the vision (a `Vision:` line in
  `areas.zortex`, and one per area), each area's objectives this period
  against the time passed, their key results and the projects those link,
  and the area's projects no key result covers, with gaps marked where
  they are. Then the week's focus (no limit on how many), the rest of the
  findings, and done projects to archive.
- **One-key fixes in the reviews**: `x` ticks a task, `d` sets its
  `@due`, `s` puts a task or a block of a project on a day, `n` adds a
  next action, `z` parks a project (`@someday`: never stale), `a`
  archives a done project or a finished task that served nothing (to
  `z/archive.tasks.zortex`), `l` links a project to a key result, `k` adds
  a key result, `p` starts a project for an area, `F` fixes a broken link
  from the search; `u` takes the last one back.
- The daily review opens with how the work done served the plan
  (`Work done: 3h30m · 60% on key results · 25% on areas only · 15% on
  neither`), lists what wasn't done with `t` to put it on the next day at
  the same time, and lists finished tasks that served neither a key result
  nor an area.
- The planner keeps the rest of a key result's project under it, folded:
  its other open tasks and each sub-project with its own (`zo` opens). The
  capacity line says how much of the day is on key results.
- The planner and the calendar view list what's **coming up**: the events
  of the next seven days (`@event` lines, and timed lines and calendar
  notes that don't link a project), to plan around
  (`ui.planner.upcoming_days`; 0 hides it).
- One XP view, `:ZortexXP` (`<leader>zxx`): the season's objectives and
  tier, XP per day for two weeks with how much of that work went to key
  results, areas only or neither, projects in progress, recent awards and
  the area tree. `:ZortexSeason start|end|status` handles seasons;
  `:ZortexXPExplain` and `:ZortexXPGuide` stay.
- Every command is listed in `:help zortex` and the README, the
  notification and pomodoro ones too: `:ZortexPomodoro` (start, pause or
  resume), `:ZortexPomodoroSkip` / `Restart` / `Stop` / `Status`,
  `:ZortexPomodoroSettings work=50 short=10 …`, `:ZortexNotify`,
  `:ZortexNotificationList`, `:ZortexNotificationsSync [force]`.
  Tools for finding problems are under one `:ZortexDebug` (`status`,
  `logs`, `level`, `timers`, `clear`, `notifications`).
- Needs Neovim 0.10 or newer (`:checkhealth zortex` says so); no deprecated
  calls are left.
- Works with nothing else installed: no picker plugin is required, the
  `vim` notification channel shows its messages, and highlights and icons
  fall back to standard groups and plain characters (no Nerd Font or
  mini.hipatterns needed).
- No personal defaults: ntfy has no default topic (nothing is sent until
  you choose a private one) and defaults to `https://ntfy.sh`;
  `:checkhealth` warns about a missing topic, and about a missing
  `zortex-notify` tag only on the public ntfy.sh.
- Notifications ship as `vim`, `system`, `ntfy` and the server; the ntfy
  provider publishes with `vim.system` and an argument list, so it no
  longer blocks the editor or breaks on quotes. Timers and alarms live in
  the web app.
- Bold headings are `**Text:**` only (the colon inside the stars).
- One way to write each thing: `.zortex` is the only extension, `@size`
  the only size spelling besides the bare `@sm`, `@lg`, … (`@sz` and
  `@every` are gone).
- The calendar view lines up icons by display width.
- Timed tasks: `16:00 [ ] Task` (or `16:00 - 17:00 [ ]`, `16:00 - [ ]`) is
  a task with a time. It notifies until it's done, sizes itself from its
  slot when ticked, and carries to today without its old time. Toggling
  `16:00 Report` makes it `16:00 [ ] Report` (it used to become
  `- [ ] 16:00 Report`). The same in `zortex serve`.
- **Labels are short now (a change to how notes parse):** a plain `Text:`
  line is a label only up to three words; a longer one is written
  `*A longer label like this one:*`. `:ZortexLongLabels` lists the lines
  that stopped being labels (and `[:Label]` link targets), to wrap the ones
  worth keeping.
- Tag searches take `is:` words: `@[rust is:heading]`, `@[rl is:open, rl
  is:label]`, `@[P/is:open]` (heading, label, item, task, open, done,
  resource).
- Inbox triage: `@project(1.4)` on an inbox line or any task says where it
  belongs; `m` in the daily review moves it there (with its nested lines),
  else to `review.inbox_default`, else to a place picked in the search.
  `@project(` completes the projects.
- Project blocks: a calendar line holding only a project link, with nothing
  under it, lists the project's next open tasks in the calendar view; `x`
  / `2x` ticks one.
- The only task under a calendar time, ticked without a `@size`, gets the
  size nearest the block's length (by ratio: 45 minutes is `@md`).
- `:ZortexRename` (`<leader>zR`) renames the heading or label under the
  cursor and rewrites every link through it.
- Broken links show as diagnostics where they are (`features.diagnostics`).
- `:ZortexBrokenLinks` also lists the tags that go nowhere: tag searches
  that find nothing, `[@Tag]` links to a tag no note has, bare tags no tag
  search asks for.
- `[P/-aB3x9]` finds a task by its `@id`, so links survive renaming it.
- A note outside `notes_dir` (a repository's `doc/Roadmap.zortex`) resolves
  its links in its own folder; `[~/P/#…]` reaches `notes_dir`.
- `@fold` keeps a section folded each time the note is shown.
- One key table (`lua/zortex/keys.lua`) for the plan, review, calendar
  view, TOC and preview buffers and the pickers: `?` lists it, the pickers
  name their keys and the backend's help key in the title, and the README
  and `:help zortex-keys` are generated from it.
- XP is said one way, "10 XP = 1 hour of estimated work", with hours next
  to XP; `xp.area_split` (default 0.5) replaces the harmonic split between
  areas with a geometric one.
- Generated links keep `&`, `'`, `,`, `?` and non-ASCII letters; only link
  syntax, `@` and `|` end them.
- Moving lines no longer leaves their link icons piled on the next line.
- `:ZortexTOC` opens on the left.
- `notifications.types.pomodoro.sound_command` takes arguments (a string or
  a list, `%s` for the file); macOS plays system sounds by default.
- The link index builds about 20× faster on a large vault (44 s to 2 s on
  1,340 notes and 28,000 links).

- `:ZortexMove` (`<leader>zM`, or a visual selection): move the section or
  the line (with its nested lines) under the cursor to a section or line
  picked in the structural search, in any note; headings re-levelled, lines
  re-indented.
- Links keep a colon inside a component: completion offers
  `[/#6.3: Homelab]` and `[/#6.3: Zortex]` instead of one `#6.3`, and
  generated links to such headings no longer resolve to the parent.
- Task groups: tasks nested under a task share its `@size` (in proportion
  to their own sizes; the group's size wins). Progress, pools and XP count
  the tasks, not the group; checking the group checks its tasks, the last
  task checks the group, reopening a task reopens the groups above it. The
  planner offers the group as one task.
- A heading's `@attributes` are highlighted like attributes on any line
  (`ZortexAttribute`), not in the heading's colours; the band behind a
  heading is its background only (`ZortexHeading1Line`..`3Line`). Folded
  headings show them the same way.
- `:ZortexPlan` run from the plan window, or over a calendar buffer the
  planner had just added the day to, works: before, `<CR>` and `p` wrote
  into the plan buffer (not modifiable / out of range), and opening the
  calendar asked to save changes you hadn't made.
- The calendar view lists the selected day as written: file order, tasks
  nested under their project's block (it sorted timed lines first).
- A time range notifies at its start only; `@n(…, end)` also notifies when
  it ends.
- `?` in the plan and review buffers lists their keys; line 1 says so.
- The search picker's keys are in `ui.search.keys` (`cycle_mode`, default
  `<M-t>`, which zellij and some terminals take; `new_note`, `<C-o>`) and
  in its title.
- `:help zortex` works for a plugin loaded from a local folder (lazy.nvim
  `dir =` / `dev = true`): `setup()` writes `doc/tags` when it is missing.
- The plan buffer lists what is left in the inbox, last.
- `<leader>zT` on a project heading marks the project done
  (`@done(today)`), asking first when it has open tasks; again reopens it.
- Reviews are written in `reviews.zortex`, one `# 2026-W43` entry per week
  with its days (`## 2026-10-21`) inside, newest first. `:ZortexReview`
  opens the week's entry (`:ZortexReview day` the day's), made from
  `review.week` / `review.day` when missing, beside the generated findings;
  nothing in the note is regenerated. A weekly review on Saturday or Sunday
  plans the coming week (`review.next_week_from`).
- The week's focus: the projects linked under `Focus:` in its entry. `f` on
  a project in the weekly review adds or removes it; the planner lists the
  focus projects and their tasks first, and a week without focus keeps the
  latest earlier week's.
- Put off: a task that was on the calendar and not done (carried on `[>]`
  or left open) ranks higher in the planner each day that happened
  (`weights.put_off`, up to `weights.put_off_max`), with a `put off ×n`
  badge; the reviews list tasks put off on two or more days.
- The plan buffer's second line is the day's capacity: the open tasks'
  `@size` hours against the free time left in `ui.planner.capacity.day`
  after timed entries that aren't project work (an entry without an end
  counts `event_minutes`). It follows edits to the day.
- `P` puts a project's next three open tasks on the day
  (`ui.planner.project_tasks`; `5P` for five), not all of them.
- The planner lists an open calendar copy of a project task as that task,
  not twice.
- Task copies: a project task put on the calendar keeps its `@id`, and lines
  with the same `@id` are one task: checked when any copy is, XP paid once
  by the project, toggling one toggles the others, `@spent` adds up. A
  calendar line without a checkbox that links a task stands for it; a
  checkbox line that links a task takes its `@id` when toggled.
- `@[rust async]` (all of the tags) and `@[rust, rl]` (any); quotes `> `,
  bullets `-`.
- `[./-Item]` links continue the link of the line they're nested under
  (`09:00 [P/#1.4 - zortex]` / `  - [ ] [./-Improve website]`), and complete
  from it: `[./-` lists that section's items, `[./#`, `[./:`, `[./*` and
  `[./>` its sections and links. `-` lists a section's items in any link.
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
  "Zortex", `<leader>zC` "Calendar", ...; `keymaps.groups`).
- Projects, areas, objectives and key results as entities with progress,
  a weekly review, a day planner, a calendar view with iCal import/export.
- XP read off completed tasks, calibrated in hours: `@size` is estimated
  time (`xp.sizes`), 10 XP an hour. Mastery (area XP) follows the plan: work
  on a project a key result links counts in full, to the objective's areas
  first; key results reached and objectives done add a completion bonus.
  `:ZortexXPGuide` shows the calibration from your config.
- Seasons are progress on their objectives (weighted by objective XP), with
  tiers at 25/50/70/85/100%; with no season started by hand, the season is
  the calendar quarter. The XP view shows both.
- The day planner ranks key-result work first, the further behind schedule
  the higher; a daily review (`:ZortexReview day`) next to the weekly one,
  both opening with what is left in the inbox, then objectives, XP on key
  results and time spent.
- [doc/Planning.md](doc/Planning.md) explains the plan, the loop and XP.
- A `notes_dir` reached through a symlink (or macOS's `/var`) is resolved,
  so the calendar, the Projects note and task links work in its buffers.
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

- **Calendar feeds** (`-feeds FILE`, NixOS `feeds.<name>`): iCal links (a
  Cozi family member's, Google's secret address, …) fetched every 15
  minutes into `z/feeds/<name>.zortex`, one line per event in the
  calendar's syntax, repeats, exceptions and time zones expanded. Per feed:
  on or off (off removes its note), whether its events notify (off by
  default) and count as busy (on by default), how often and how far ahead.
  The home page lists their events among yours, labelled; a notifying
  feed's days get a dot of their own on the month grid, in the feed's
  `color`.
- **`/calendar.ics`**: the calendar's lines tagged `@share` as an iCal feed
  for Cozi, Google or Apple to subscribe to. `-share-token-file` (NixOS
  `shareTokenFile`) lets `?token=…` in without the login; behind a proxy
  with a login, let that one path through (doc/Server.md has an Authelia
  rule).
- The inbox box works offline in the installed app: what you add without a
  connection (or while the server is down) is kept in the browser and
  appended to the bottom of `inbox.zortex`, in order, when it's back. A
  capture whose answer was lost is added once. The `/offline` page has the
  box too, and the installed app has an "Add to inbox" shortcut.
- The home page has one search box, the header's (it lists matching notes
  as you type); the second box above the inbox is gone.
- `/api/calendar` no longer returns `events` / `text_view`, and the
  notification sync's reply no longer has `upserted`.
- A `- Key: text` item wraps under its key, not in a column after it.
- No personal time zone: the NixOS module follows `time.timeZone`, and
  docker-compose sets no `TZ`.
- `/okr` (Objectives in the top bar): objectives against the time passed in
  their period, their key results and the projects behind them. `/review`:
  the weekly review's findings, for any week.
- Hover cards on links: a note's title, path, tags, first lines and
  backlinks; an image; a website's domain and URL (nothing is fetched).
- `/graph` lists, under each note, the headings other notes link to.
- The search page has a Text mode, and with `-data` its own search history
  (`search_history.json`, never in the notes' `.z/`).
- `/broken` lists the tags that go nowhere, apart from broken links.
- The labels rule, `is:` tag searches, `[P/-id]` links and the calendar
  auto-size are the same as in Neovim (shared fixtures:
  `autosize.json`, `calendar.json`, `resolve.json`, `search.json`).
- The web calendar reads entries like Neovim's (`- 14:00 x`, `7:05`, an
  `@2h` end, four-space nesting), and lists a project block's next tasks.
- The home page's title is "Zortex"; XP shows its hours of work.

- Task groups as in Neovim (`app/edit` Groups and Cascade, checked against
  `tests/fixtures/groups.json`): project pages list a group's tasks with
  their share and the group's name, ticking cascades (through calendar
  copies too), and a task ticked on the web is estimated at its share.
- The web app installs as an app (a PWA: home screen on a phone, its own
  window on the desktop), and the last 60 pages you opened read offline as
  saved copies ([doc/Server.md](doc/Server.md#installing-it-as-an-app)).
- An attribute in a heading looks like one on a text line (not bold, not
  heading-sized).
- The header's search box lists the notes whose name matches as you type.
- A bare `@tag` links to the lines tagged so in every note (`@[*/tag]`).
- Tag tables: no Notes column; an item's notes show under it (all of them
  up to three lines, else the first two and an "All notes" button).
- Calendar: the 🔔 marks lines with a written `@n(…)` (every timed line
  notifies by default), and the month grid's dot marks days with an
  `@event`.
- Project pages: `/projects` lists the week's focus projects, then every
  project with open work, with progress (task `@size` hours) and the next
  task; `/project?rel=&lnum=` shows one: progress and time tracked, its
  next tasks (put off how often, planned when), sub-projects, the key
  results it moves and how far behind they are, its `Log:`, the days it was
  on the calendar, and the notes and files it links and that link it. With
  `-writable` its tasks can be ticked and `POST /api/project/log` adds a
  dated line to its log. The home page shows the week's focus.
- Tasks completed on the web count once per `@id` (a calendar copy and its
  project task are one) and are estimated in XP until Neovim counts them:
  `/api/xp` has `pending_xp` and `pending_tasks`, from the calibration
  Neovim now publishes with the XP summary.
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

### Project

- MIT license; the old Node app (`legacy/`), its VimL bridge (`autoload/`),
  the old test harness, dead code and compatibility shims for earlier names
  and note forms are gone.
- CI on every push: the Lua tests on Neovim 0.10, stable and nightly (and
  against snacks.nvim, telescope, fzf-lua and blink.cmp), `go test -race`,
  `gofmt`, and a check that generated docs and fixtures are up to date.
  Tags build the release binaries and the container image; the Nix package
  takes its version from the tag and runs the Go tests in its build.
- Documentation for someone new: a README with a quickstart, `:help
  zortex` (commands, keys and every configuration default, generated),
  one syntax reference checked against the parser
  ([doc/Syntax.md](doc/Syntax.md)), an example vault
  ([doc/example](doc/example)), a server guide
  ([doc/Server.md](doc/Server.md)) and the ideas behind it
  ([doc/Philosophy.md](doc/Philosophy.md)).
