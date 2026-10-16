# zortex.nvim

A plain-text life-management system for Neovim. It started as a
Zettelkasten and second-brain experiment and grew into one folder that holds
what you know and what you're doing: notes, projects, areas, objectives, a
calendar and a pomodoro, all linked to each other. Notes are `.zortex`
files (a markdown dialect) that link by structure, not ids:
`[Sourdough/#Method]`, `[P/#1.1 Kitchen shelves]`. The backlinks, tags,
embeds, graph and slides you'd expect from Obsidian are here too, in plain
text you own and sync however you like.

<p align="center">
  <img src="doc/images/nvim-projects.png" width="49%" alt="A projects note in Neovim: headings, tasks with sizes and dates, links">
  <img src="doc/images/web-home.png" width="49%" alt="The web app's home page: today's calendar, the pomodoro and the season">
</p>

**Notes and knowledge**

- **Structural search** over every note: `2 4` finds `1 › 2 › 3 › 4`, and a
  file name finds its note. Hundreds of notes and tens of thousands of
  lines stay instant.
- **Links** that name structure: follow, preview, complete while typing,
  backlinks, and **broken-link tracking** in Neovim, the reviews and the
  web app.
- **Tag tables**: `!@[@Library/rust]` gathers the lines tagged `@rust` in
  every `@Library` note into a table, in place.
- **Slides**: any note is a deck (`:ZortexPresent`), with speaker notes,
  items revealed step by step, images and math.

**Planning and doing**

- **Projects, areas and OKRs** (PARA plus objectives and key results) with
  progress, due dates and daily and weekly reviews written in one
  `reviews.zortex`; each week's **focus projects**; a **day planner** that
  fills the calendar, focus and key-result work first, ranks up tasks put
  off again and again, and says when the day is full.
- **XP that follows the plan**: finished tasks pay XP by their estimated
  hours, work on a project a key result links counts toward that
  objective's areas, and the season is progress on this quarter's
  objectives. Getting PARA work done shows up as OKR results, with no
  bookkeeping.
- **Pomodoro** shared by Neovim and the browser; its time goes to the
  calendar task you're on (`@spent(1h25m)`).
- **Inbox**: jot a thought down from the web app (or Neovim) and the next
  review lists it for you to file away.

**On the web** (`zortex serve`, optional: one Go binary)

- Your notes rendered and searchable, with the calendar, the pomodoro and
  XP on the home page, light editing from your phone, and ntfy
  notifications.
- **Project pages**: progress, next tasks, the key results they move, a log
  of where you left off, the days they were on the calendar, and the notes
  and files they link.
- A **note graph**: the Structure note as cards, the notes each one links
  with marked on hover, and the notes it doesn't reach.
- A **personal file viewer**: PDFs, images, video, Markdown with math
  (KaTeX), sandboxed HTML; each file shows which notes link to it, and
  `/resources` lists the ones nothing links to.

## Quickstart

Needs Neovim 0.10 or newer. Linux and macOS; Windows untested. With
[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "t-wilkinson/zortex.nvim",
  opts = { notes_dir = "~/zortex" },
  -- optional, to load on demand (calendar notifications and the starter
  -- notes then wait until it loads):
  -- ft = "zortex", cmd = { "ZortexSearch", "ZortexPlan" }, keys = { "<leader>z" },
}
```

Pickers use whichever of [snacks.nvim](https://github.com/folke/snacks.nvim),
[telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) or
[fzf-lua](https://github.com/ibhagwan/fzf-lua) you have (LazyVim's choice
when you use LazyVim), and link completion
[blink.cmp](https://github.com/Saghen/blink.cmp) or
[nvim-cmp](https://github.com/hrsh7th/nvim-cmp); nothing to configure (see
[Pickers and completion](#pickers-and-completion)). Without a picker plugin,
`vim.ui.select` lists the results.

Then, in five minutes:

1. **Start Neovim.** `~/zortex` is created with the key notes: `structure`,
   `projects`, `areas`, `okr`, `calendar` and `inbox`, from short templates
   that link to each other. (In a folder that already has notes nothing is
   written; `:ZortexInit` adds what's missing.)
2. **Open the structure note**, the map of everything: `<leader>zfs`. Notes
   open folded to their headings: `zR` opens every fold, `zo` the one under
   the cursor (`features = { folding = { level = 99 } }` starts unfolded).
   Put the cursor on `[Projects]` and follow it with `<leader>zgx`.
3. **Add a task** under `# 1 Example project`: `- [ ] Read the docs @size(sm)`.
   Toggle it with `<leader>zT`: it becomes `[x]` with `@done(today)` (and
   an `@id`, which keeps links and the web app pointing at it).
4. **Write a note**: `:e ~/zortex/bread.zortex`, first line `@@Bread`, then
   `# Method` and a few lines. Back in the structure note, type `[Bre`:
   completion offers `Bread`; `[Bread/#Method]` links to the heading.
5. **Search** with `<leader>zz`: type `bread meth` (words match the section
   path in order).
6. **Plan the day** with `<leader>zm`: today's calendar next to your tasks;
   `p` puts one on the day.

Next: the note format is in [doc/Syntax.md](doc/Syntax.md),
[doc/example](doc/example) is a small folder using most of it, and
`:checkhealth zortex` checks the setup. The server is optional; see
[doc/Server.md](doc/Server.md), which also covers keeping the notes in sync
with a server (Syncthing, Nextcloud, Unison, git or rsync).

**Configuration.** Every option and its default is in
[`lua/zortex/config.lua`](lua/zortex/config.lua); `setup()` merges yours over
them. Commonly changed: `keymaps.prefix` (default `<leader>z`),
`ui.highlights` (colours follow your colorscheme; `preset = "rose-pine"` for
the author's palette), `ui.calendar.icons` (plain Unicode; a Nerd Font set
is in a comment there), `ui.planner.templates` (a new calendar day's lines)
and `xp` (how many hours each `@size` stands for, and what that is worth;
`:ZortexXPGuide` shows it).

## Notes

Every note is a `.zortex` file under `notes_dir`. Notes go in `notes_dir`
itself; `z/` holds resources (PDFs, images, books) and archives. Notes in
subfolders work too. A note starts with a header:

```
@@Projects          article name (the first @@ line)
@@P                 alias
@Me                 tag
@size(lg)           header attribute
```

The body has headings (`#` … `######`), bold headings (`**Next steps:**`),
labels (`Ideas:`), list items and tasks (`- [ ] task @size(sm)`,
`14:00 event`), attributes (`@p1`, `@due(2026-10-20)`, `@a(4.1)`), links
(`[P/#1.4 - zortex]`, `[A/#1.2/:Fitness]`, `[/#Local heading]`) and the
usual markdown blocks and inline markup. **[doc/Syntax.md](doc/Syntax.md)** is
the complete reference; a test checks its examples against the parser.

Special notes:

- **`projects.zortex`** (`@@Projects` / `@@P`): headings are projects and
  sub-projects; any note tagged `@P` is a project too. Link them as `[P/…]`.
- **`areas.zortex`** (`@@Areas` / `@@A`): headings and labels are areas;
  `@a(4.1)` on a project or objective links it to an area.
- **`okr.zortex`**: headings like `## 3M-2026-Q1 Title` are objectives; their
  `- KRn:` items are key results, and project links on a KR drive its
  progress.
- **`calendar.zortex`**: `YYYY-MM-DD:` labels with entries under them
  (`- [ ] task`, `14:00 event`, `- note`).
- Notes tagged `@Archive` (or named `z/archive.*`) are left out of links,
  projects and search ranking.

[doc/Projects.md](doc/Projects.md) has the full projects and areas reference.

## What it does

- **Structural search** (`<leader>zz`): words match a section's path in order
  (`2 4` finds `1 › 2 › 3 › 4`), results are breadcrumbs ranked by hierarchy,
  and what you open often ranks higher. A note's file name is one more
  alias of its articles (`okr` finds `@@Objectives` in `okr.zortex`). `<leader>z/` searches plain text in
  every line instead; `<M-t>` in the picker cycles section, article and text
  search (`ui.search.keys.cycle_mode` changes the key, e.g. `<C-t>` when a
  terminal or zellij takes `<M-t>`).
- **which-key**: when [which-key.nvim](https://github.com/folke/which-key.nvim)
  is installed, `<leader>z` shows as "Zortex" and its sub-prefixes by name
  (`<leader>zC` "Calendar & digest", `<leader>zx` "XP", ...); rename them
  with `keymaps.groups`.
- **Links**: follow (`<leader>zgx`), open in the web app (`<leader>zgX`),
  preview in a float (`<leader>zK`, or on hover with
  `ui = { preview = { on_hover = true } }`), complete while typing (tags
  too, after `@` and in `@[...]`), backlinks and broken links in the
  quickfix list. A persistent link index keeps this fast.
- **Highlighting and folding** for the whole format, with concealed markers.
- **Projects**: picker with progress, points, due dates, areas and key
  results; `@progress` written back on request.
- **Day planner** (`<leader>zm`): opens today's calendar day (created from
  your weekday/Saturday/Sunday template) next to ranked candidates: the
  week's focus projects first, then tasks on key results (the further a key
  result is behind schedule, the higher), then work with only an area, then
  the rest; due dates, priority and how often a task was put off add on
  top. A capacity line weighs the day's tasks against its free time. `p`
  adds an item (with a link to it) to the day and stays in the list; `P` a
  project with its next three tasks; `i`/`o`/`O` put it on the
  current/next/previous line and let you type its time.
- **Reviews**: daily (`<leader>zW`, since the last one) and weekly
  (`<leader>zw`), written in `reviews.zortex` (a week's entry with its days
  inside) with the findings beside it. Both open with what is left in the
  inbox, the week's focus and tasks put off again and again, then your
  objectives and key results against the time passed, the XP earned and how
  much of it was on key results, and the time spent per task; then what you
  completed, what's overdue or due, and (weekly) the projects to pick the
  week's focus from (`f`), stale and unscheduled projects, key results
  without projects, areas without an objective, broken links. Every line
  links to its source.
- **Calendar**: month/week views with project tasks and due dates, a digest
  panel, iCal import/export, notifications (synced to `zortex serve` and sent
  through ntfy; unchanged calendars aren't re-sent).
- **Pomodoro** (`<leader>zoo`): one clock shared with the web app's home page,
  with ntfy alerts and a different sound for work, breaks and a new cycle.
  Timers, alarms and a stopwatch are on the home page too, and their time
  goes to the task you're working on (`@spent(1h25m)`; by default the
  current calendar entry).
- **Planning and XP**: areas → objectives → key results → projects → tasks,
  a week's focus projects, a day planner that puts focus and key-result
  work first, daily and weekly reviews,
  and XP that mirrors it (seasons for this quarter's objectives, Mastery for
  areas). See
  [doc/Planning.md](doc/Planning.md).
- **Export** (`:ZortexExport`): the notes and the whole model as JSON.

## Commands and keys

Every action is one entry in [`lua/zortex/actions.lua`](lua/zortex/actions.lua);
commands, keymaps and `require("zortex").actions` are generated from it, and
`:ZortexHelp` (`<leader>z?`) lists them with your prefixes. Change a key with
`keymaps.mappings`:

```lua
require("zortex").setup({
  keymaps = {
    prefix = "<leader>z",
    mappings = { task_toggle = "t", search_articles = false, review = { "w", "R" } },
  },
})
```

<!-- actions:start -->
**Find**

| Command | Keys | Action id | Does |
|---|---|---|---|
| `:ZortexSearch` | `<leader>zz` | `search` | Search sections and lines (structural search) |
| `:ZortexSearchArticles` | `<leader>zZ` | `search_articles` | Search article names |
| `:ZortexSearchText` | `<leader>z/` | `search_text` | Search plain text in every line (smart case) |
| `:ZortexProjects` | `<leader>zp` | `projects` | Browse projects |
| `:ZortexTOC` | `<leader>zl` | `toc` | Table of contents of this note |
| `:ZortexTOCPopup` | `<leader>zL` | `toc_popup` | Table of contents in a popup |

**Links**

| Command | Keys | Action id | Does |
|---|---|---|---|
| `:ZortexLinkOpen` | `<leader>zgx` | `link_open` | Follow the link under the cursor |
| `:ZortexLinkOpenWeb` | `<leader>zgX` | `link_open_web` | Open the link under the cursor (or this line) in the web app |
| `:ZortexLinkPreview` | `<leader>zK` | `link_preview` | Preview the link target in a float |
| `:ZortexBacklinks` | `<leader>zb` | `backlinks` | Links into the section under the cursor (quickfix) |
| `:ZortexBrokenLinks` | `<leader>zB` | `broken_links` | Links that resolve nowhere (quickfix) |
| `:ZortexLinkIndexRebuild` |  | `link_index_rebuild` | Rebuild the link index from scratch |

**Structure**

| Command | Keys | Action id | Does |
|---|---|---|---|
| `:ZortexSectionNext` | `<leader>z]` | `section_next` | Next section at the same or higher level |
| `:ZortexSectionPrev` | `<leader>z[` | `section_prev` | Previous section at the same or higher level |
| `:ZortexSectionParent` | `<leader>z^` | `section_parent` | Parent section |
| `:ZortexFoldsUpdate` | `<leader>zr` | `folds_update` | Recompute folds |
| `:ZortexArchiveSection` | `<leader>za` | `archive_section` | Move the section under the cursor to the note's z/archive file |

**Tasks**

| Command | Keys | Action id | Does |
|---|---|---|---|
| `:ZortexTaskToggle` | `<leader>zT` | `task_toggle` | Toggle the task on this line (makes one if needed); on a project heading, mark the project done |
| `:ZortexTaskComplete` | `<leader>ztc` | `task_complete` | Complete the task on this line |
| `:ZortexTaskUncomplete` | `<leader>ztu` | `task_uncomplete` | Reopen the task on this line |
| `:ZortexTaskConvert` | `<leader>ztt` | `task_convert` | Turn this line into a task |
| `:ZortexProjectProgress` | `<leader>zu` | `project_progress` | Write @progress(done/total) on project headings in this buffer |

**Plan**

| Command | Keys | Action id | Does |
|---|---|---|---|
| `:ZortexReview …` | `<leader>zw` | `review` | Review: week (default), day (since the last daily review), or a number of days |
| `:ZortexReviewDay` | `<leader>zW` | `review_day` | Daily review: completed, XP, time spent and the calendar since the last one |
| `:ZortexPlan …` | `<leader>zm` | `plan` | Plan a day: calendar day (from its template) plus ranked tasks, projects, KRs and areas to put on it |
| `:ZortexCarryForward …` | `<leader>zCf` | `carry_forward` | Copy the open tasks of the days before to today (or a date), marking the old lines [>] |
| `:ZortexCalendar` | `<leader>zc` | `calendar` | Calendar view |
| `:ZortexCalendarDigest` | `<leader>zCc` | `calendar_digest` | Calendar view with the digest panel |
| `:ZortexDigest` | `<leader>zCd` | `digest` | Open the digest note |
| `:ZortexDigestUpdate` | `<leader>zCD` | `digest_update` | Regenerate the digest note |

**Pomodoro**

| Command | Keys | Action id | Does |
|---|---|---|---|
|  | `<leader>zoo` | `pomodoro_toggle` | Start, pause or resume the pomodoro |
|  | `<leader>zos` | `pomodoro_skip` | End the current pomodoro phase now |
|  | `<leader>zor` | `pomodoro_restart` | Begin a new pomodoro cycle |
|  | `<leader>zox` | `pomodoro_stop` | Stop the pomodoro |
|  | `<leader>zoi` | `pomodoro_status` | Show the pomodoro status |

**Calendar**

| Command | Keys | Action id | Does |
|---|---|---|---|
| `:ZortexNotificationsSync …` |  | `notifications_sync` | Sync calendar notifications (to the server if enabled); `force` resends unchanged |
| `:ZortexIcalImport` |  | `ical_import` | Import an iCal file or URL into the calendar |
| `:ZortexIcalExport` |  | `ical_export` | Export the calendar to an iCal file |

**Files**

| Command | Keys | Action id | Does |
|---|---|---|---|
| `:ZortexInit` |  | `init` | Create missing key notes (calendar, projects, areas, okr, structure, inbox) |
| `:ZortexOpenProjects` | `<leader>zfp` `<leader>zP` | `open_projects` | Open projects.zortex |
| `:ZortexOpenAreas` | `<leader>zfa` | `open_areas` | Open areas.zortex |
| `:ZortexOpenOKR` | `<leader>zfo` | `open_okr` | Open okr.zortex |
| `:ZortexOpenCalendar` | `<leader>zfc` | `open_calendar` | Open calendar.zortex |
| `:ZortexOpenStructure` | `<leader>zfs` | `open_structure` | Open structure.zortex |
| `:ZortexOpenInbox` | `<leader>zfi` | `open_inbox` | Open inbox.zortex |
| `:ZortexPresent` | `<leader>zS` | `present` | Present this note as slides in the web app, from the slide under the cursor |

**XP**

| Command | Keys | Action id | Does |
|---|---|---|---|
| `:ZortexMasteryTree` | `<leader>zk` | `mastery_tree` | Mastery tree and season progress |
| `:ZortexXPStats` | `<leader>zxs` | `xp_stats` | XP statistics |
| `:ZortexXPAreas` | `<leader>zxa` | `xp_areas` | Top areas by XP |
| `:ZortexXPExplain` | `<leader>zxe` | `xp_explain` | How the project at the cursor earned its XP |
| `:ZortexXPGuide` | `<leader>zxg` | `xp_guide` | How XP is calibrated: hours per @size, Mastery, tiers |
| `:ZortexSeasonStatus` |  | `season_status` | Current season |
| `:ZortexSeasonStart …` |  | `season_start` | Start a season: [name] [end YYYY-MM-DD] [start YYYY-MM-DD] (prompts without args) |
| `:ZortexSeasonEnd` |  | `season_end` | End the current season |

**System**

| Command | Keys | Action id | Does |
|---|---|---|---|
| `:ZortexExport …` |  | `export` | Export notes and the model as JSON (default notes_dir/.z/export) |
| `:ZortexStatus` |  | `status` | Counts, state directory and event timings |
| `:ZortexLogs …` |  | `logs` | Recent log entries (optional count) |
| `:ZortexLogLevel …` |  | `log_level` | Set the log level |
| `:ZortexPerformance` |  | `performance` | Timer statistics |
| `:ZortexClearLogs` |  | `clear_logs` | Clear logs and timers |
| `:ZortexHelp` | `<leader>z?` | `help` | List commands and keys |
<!-- actions:end -->

Inside the calendar view: `h/j/k/l` days and weeks, `H/J/K/L` years and
months, `t` today, `a` add, `<CR>` entries, `v` toggle month/week, `d`
digest panel, `/` search the entries, `gf` go to the file, `n` sync
notifications, `?` help, `q` close (`ui.calendar.keymaps`). In the review
buffer: `<CR>` jump to the source, `f` add a project to the week's focus,
`gx`/`K` follow or preview, `r` refresh, `q` close. The plan and review
buffers list their keys with `?`.

### Pickers and completion

Search, projects, calendar entries and `>` links that match several links
open in one picker, on the plugin you have: `ui.picker = "auto"` takes
LazyVim's picker (`vim.g.lazyvim_picker`), else a snacks.picker you enabled,
telescope, fzf-lua, snacks.picker, and `vim.ui.select` when none is
installed. Or name one: `"snacks"`, `"telescope"`, `"fzf_lua"`, `"select"`.

The picker's own keys open a row (`<CR>`, and its split / vsplit / tab
keys), select several (`<Tab>`; they go to the quickfix list and the first
opens) and send rows to the quickfix list (`<C-q>`, fzf-lua `alt-q`). The
zortex keys are the same everywhere: Ctrl acts on the row, Alt changes the
list.

| picker   | keys                                                                                                     |
| -------- | -------------------------------------------------------------------------------------------------------- |
| search   | `<C-o>` new note named after the query, `<M-t>` cycle section / article / text search (`ui.search.keys`; shown in the title) |
| projects | `<C-l>` insert the link, `<C-y>` yank it, `<M-s>` cycle the sort, `<M-d>` show done, `<M-e>` leaf only     |
| follow   | `<C-l>` go to the link's line instead of following it                                                    |

Link completion (`[`, `/`, `#`, `>`, `@a(`, ...) registers itself on the
first zortex buffer: with blink.cmp as the `zortex` provider, listed for
zortex buffers next to your default sources; with nvim-cmp in the zortex
buffers' sources. To list it elsewhere (markdown, say), in blink.cmp's
options:

```lua
sources = {
  per_filetype = { markdown = { inherit_defaults = true, "zortex" } },
  providers = { zortex = { name = "Zortex", module = "zortex.features.blink" } },
}
```

## Lua API

`require("zortex")` is the API. Services load on first use:

```lua
local z = require("zortex")

z.actions.review()                        -- any action by id
z.run("review", { args = "14" })          -- with command-style arguments

z.query.search("1.4 zortex")              -- plain data, JSON-safe
z.query.note("projects.zortex")           -- header, outline, full syntax
z.query.tree("z")                         -- folders and notes
z.query.review({ days = 7 })

z.projects.all()                          -- Project entities
z.projects.resolve("[P/#1.4 - zortex]"):rollup()
z.okr.key_results({ open = true })
z.agenda.upcoming(7)
z.links.resolve_first("[A/#1 Personal Foundation]")
z.document.get(path).syntax               -- the parsed note
z.syntax.parse(lines, { inline = true })  -- the grammar itself

-- in a statusline: "🍅 12:34" while a pomodoro runs, "" otherwise
require("zortex.notifications.types.pomodoro").statusline()
```

| name                                     | module            | what                                                                                                                                                |
| ---------------------------------------- | ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `query`                                  | `zortex.query`    | plain-data views: `tree`, `note`, `search`, `resolve`, `backlinks`, `broken_links`, `projects`, `areas`, `objectives`, `agenda`, `review`, `export` |
| `projects`, `areas`, `okr`               | `services/*`      | entities: `all`, `get`, `at`, `resolve`, plus `query`/`tasks` (projects), `objectives`/`key_results` (OKR)                                          |
| `agenda`                                 | `services/agenda` | `day`, `range`, `upcoming`, `review`                                                                                                                |
| `calendar`                               | `stores/calendar` | entries by date, `add_entry`, `update_entry`, `delete_entry`                                                                                        |
| `tasks`                                  | `services/tasks`  | toggle/complete on the cursor line, `find_task_by_id`                                                                                               |
| `search`, `search_history`               | `services/*`      | structural search and its ranking history                                                                                                           |
| `digest`, `review`, `xp`                 |                   | digest note, review buffer, XP and seasons                                                                                                          |
| `notes`, `document`, `syntax`, `item`    | `core/*`          | note index, parsed snapshots, grammar, list items                                                                                                   |
| `links`, `link_index`                    |                   | link resolution and the index of every link                                                                                                         |
| `workspace`, `state`, `events`, `config` |                   | line edits, `.z` state files, domain events, configuration                                                                                          |

## Documentation

- `:help zortex`: setup, commands and keys, every configuration default
- [doc/Syntax.md](doc/Syntax.md): the note format (lines, inline markup,
  attributes, links, special notes)
- [doc/example](doc/example): a small notes folder using most of the format
- [doc/Server.md](doc/Server.md): running `zortex serve` (Docker, NixOS, a
  proxy with a login, ntfy, connecting Neovim); [app/README.md](app/README.md)
  has every flag, page and endpoint
- [doc/Projects.md](doc/Projects.md): projects and areas reference
- [doc/Planning.md](doc/Planning.md): the plan (areas, OKRs, projects),
  the daily and weekly loop, and how XP, Mastery and seasons work
- [doc/Architecture.md](doc/Architecture.md): how the plugin is built (syntax,
  documents, links, entities, domain, state, query API, UI) and the rules
  modules share
- [CHANGELOG.md](CHANGELOG.md): releases, and what to change when upgrading
- [CONTRIBUTING.md](CONTRIBUTING.md): tests, generated files, releasing
- [doc/Wishlist.md](doc/Wishlist.md): planned features and ideas
- [doc/Philosophy.md](doc/Philosophy.md): why zortex is a personal wiki, not
  a Zettelkasten
- [contrib/ntfy](contrib/ntfy): desktop `ntfy subscribe` script with a sound
  per event
- Tests: `nvim --headless -u NONE -l tests/run.lua`; Go (parser, resolver,
  search, web app, notifications, pomodoro, clocks, time tracking):
  `go -C app test ./...`. CI runs both on every push.
