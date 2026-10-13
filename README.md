# zortex.nvim

### What is this?

This is mean to be a second brain. An all-in-one personal management system. The goal is to allow one to store notes, todo lists, schedules, thoughts, etc. in a single location. It includes:

- A plain-text note format (a derivative of markdown) with articles, headings, labels, tasks, attributes and links between notes.
- Projects, areas (PARA), objectives and key results (OKR) and a calendar, all written in that format and connected through links.
- Fast structural search over every note. Currently I have 300 pages, at 38,000 lines, and can still immediately find what I need.
- A weekly review, a daily digest, notifications and an XP system on top.

### Purpose

Originally I had set to replicate the zettelkasten technique more closely, where each line was a different thought with a unique id and various tags. You could then query thoughts with certain tags. Although conceptually very interesting, I didn't actually find it useful. It allowed a purely flat layout of all my thoughts. However it had a few flaws:

- It was complicated.
- I was never encouraged to actually think and integrate my thoughts into something more meaningful as I would rely on the tag system to organize my notes.
- It discouraged thinking deeply about concepts.
- By design, it lacks a single source of truth for concepts. I'm limited

I found this new system better:

- Have a couple _core_ files:
  - **Structure:** is the most importantt. It is a single file that links to all my other notes. Using vim's folding, You can get an overview of the main domains of your wikipedia, or dive down. You can put the same article in multiple locations. This allows you to continue a graph-like knowledge base, while attaching a lot of information, depth, and thought into each thought.
  - **Storage:** this is a collection of all my old files/thoughts that it will not search through. Good for stuff I will probably never need again, but keep there just in case.
  - **Resources:**
  - **Schedule:**
  - **Projects:**
  - **Inbox:** a file that somewhat matches the original zettelkasten. Each 'unique' id is the line number. You can add tags to each line.
- Prefix lines with tags such as `- #one#two# This is my line text.` Provides a natural, intuitive way to organize thoughts that can still be easily searched. Provides a natural, intuitive way to organize thoughts that can still be easily searched.
- To still express the graph knowledge that the zettelkasten provides, I've found a hybrid approach of within your articles, add subheadings that refer to or connect ideas to other articles. Which is exactly what wikipedia does.

However this is not how I think. Overtime, I found my usecase of a note system closely mirrored a personal wikipedia. I would have 10s-100s of articles that I could quickly search.

### Where did the name come from?

- Zettelkasten (german for note "zettel" desk "kasten") was a note taking system popularized by Niklas Luhmann, a very prolific sociologist.
- Cortex, latin for bark. Its found in the word "neocortex" and "cerebral cortex". The neocortex is a key component in cognition. The Zortex is meant to be a sort of second brain.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "t-wilkinson/zortex.nvim",
  dependencies = { "nvim-telescope/telescope.nvim" }, -- optional: search and project pickers
  config = function()
    require("zortex").setup({
      notes_dir = "~/zortex/",
      keymaps = { prefix = "<leader>z" },
    })
  end,
}
```

Optional: [nvim-cmp](https://github.com/hrsh7th/nvim-cmp) for link completion
(the `zortex` source is registered automatically). `:checkhealth zortex`
checks the setup.

In a new (empty) notes folder, `setup()` creates the key notes from short
templates that link to each other: `calendar`, `projects`, `areas`, `okr`,
`structure` and `inbox`. In a folder that already has notes it never writes
(a missing file may just not have synced yet); it tells you once what is
missing, and `:ZortexInit` creates those. `init_files = false` turns this
off.

## Notes

Every note is a `.zortex` file under `notes_dir` (subfolders included; `z/`
is the usual place for the library). A note starts with a header:

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
  and what you open often ranks higher.
- **Links**: follow (`<leader>zgx`), preview in a float (`<leader>zK`, or on
  hover with `ui = { preview = { on_hover = true } }`), complete while typing,
  backlinks and broken links in the quickfix list. A persistent link index
  keeps this fast.
- **Highlighting and folding** for the whole format, with concealed markers.
- **Projects**: picker with progress, points, due dates, areas and key
  results; `@progress` written back on request.
- **Day planner** (`<leader>zm`): opens today's calendar day (created from
  your weekday/Saturday/Sunday template) next to a ranked list of TODOs,
  high-priority and due tasks, OKR projects, key results and areas. `p` adds
  an item (with a link to it) to the day and stays in the list; `i`/`o`/`O`
  put it on the current/next/previous line and let you type its time.
- **Weekly review** (`<leader>zw`): overdue and due tasks, completed work,
  stale and unscheduled projects, projects without a next action, KRs
  without projects, areas without projects, broken links. Every line links
  to its source.
- **Calendar**: month/week views with project tasks and due dates, a digest
  panel, iCal import/export, notifications (synced to `zortex serve` and sent
  through ntfy; unchanged calendars aren't re-sent).
- **Pomodoro** (`<leader>zoo`): one clock shared with the web app's home page,
  with ntfy alerts and a different sound for work, breaks and a new cycle.
  Timers, alarms and a stopwatch are on the home page too, and their time
  goes to the task you're working on (`@spent(1h25m)`; by default the
  current calendar entry).
- **XP and seasons** read off completed tasks, projects and objectives,
  distributed to areas; a skill tree. See [doc/XP.md](doc/XP.md).
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
| `:ZortexProjects` | `<leader>zp` | `projects` | Browse projects |
| `:ZortexTOC` | `<leader>zl` | `toc` | Table of contents of this note |
| `:ZortexTOCPopup` | `<leader>zL` | `toc_popup` | Table of contents in a popup |

**Links**

| Command | Keys | Action id | Does |
|---|---|---|---|
| `:ZortexLinkOpen` | `<leader>zgx` | `link_open` | Follow the link under the cursor |
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
| `:ZortexTaskToggle` | `<leader>zT` | `task_toggle` | Toggle the task on this line (makes one if needed) |
| `:ZortexTaskComplete` | `<leader>ztc` | `task_complete` | Complete the task on this line |
| `:ZortexTaskUncomplete` | `<leader>ztu` | `task_uncomplete` | Reopen the task on this line |
| `:ZortexTaskConvert` | `<leader>ztt` | `task_convert` | Turn this line into a task |
| `:ZortexProjectProgress` | `<leader>zu` | `project_progress` | Write @progress(done/total) on project headings in this buffer |

**Plan**

| Command | Keys | Action id | Does |
|---|---|---|---|
| `:ZortexReview …` | `<leader>zw` | `review` | Weekly review (optional window in days, default 7) |
| `:ZortexPlan …` | `<leader>zm` | `plan` | Plan a day: calendar day (from its template) plus ranked tasks, projects, KRs and areas to put on it |
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

**Plan**

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

**XP**

| Command | Keys | Action id | Does |
|---|---|---|---|
| `:ZortexSkillTree` | `<leader>zk` | `skill_tree` | Skill tree and season progress |
| `:ZortexXPStats` | `<leader>zxs` | `xp_stats` | XP statistics |
| `:ZortexXPAreas` | `<leader>zxa` | `xp_areas` | Top areas by XP |
| `:ZortexXPExplain` | `<leader>zxe` | `xp_explain` | How the project at the cursor earned its XP |
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
months, `t` today, `a` add, `e` edit, `x` delete, `<CR>` entries, `v` toggle
month/week, `d` digest panel, `/` search, `gf` go to the file, `n` sync
notifications, `?` help, `q` close (`ui.calendar.keymaps`). In the review
buffer: `<CR>` jump to the source, `gx`/`K` follow or preview, `r` refresh,
`q` close.

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
```

| name | module | what |
|---|---|---|
| `query` | `zortex.query` | plain-data views: `tree`, `note`, `search`, `resolve`, `backlinks`, `broken_links`, `projects`, `areas`, `objectives`, `agenda`, `review`, `export` |
| `projects`, `areas`, `okr` | `services/*` | entities: `all`, `get`, `at`, `resolve`, plus `query`/`tasks` (projects), `objectives`/`key_results` (OKR) |
| `agenda` | `services/agenda` | `day`, `range`, `upcoming`, `review` |
| `calendar` | `stores/calendar` | entries by date, `add_entry`, `update_entry`, `delete_entry` |
| `tasks` | `services/tasks` | toggle/complete on the cursor line, `find_task_by_id` |
| `search`, `search_history` | `services/*` | structural search and its ranking history |
| `digest`, `review`, `xp` | | digest note and email, review buffer, XP and seasons |
| `notes`, `document`, `syntax`, `item` | `core/*` | note index, parsed snapshots, grammar, list items |
| `links`, `link_index` | | link resolution and the index of every link |
| `workspace`, `state`, `events`, `config` | | line edits, `.z` state files, domain events, configuration |

## Documentation

- [doc/Syntax.md](doc/Syntax.md): the note format (lines, inline markup,
  attributes, links, special notes)
- [doc/Architecture.md](doc/Architecture.md): how the plugin is built (syntax,
  documents, links, entities, domain, state, query API, UI) and the rules
  modules share
- [doc/Projects.md](doc/Projects.md): projects and areas reference
- [doc/Changes.md](doc/Changes.md): what the `projects-api` branch changed,
  and migration notes
- [doc/Wishlist.md](doc/Wishlist.md): planned features and ideas
- [doc/XP.md](doc/XP.md): how XP, areas and seasons work
- [app/README.md](app/README.md): the server, `zortex serve` (rendered notes,
  links, backlinks, search, file browser; the calendar and its ntfy
  notifications; the pomodoro clock), with the NixOS module (`services.zortex`)
- [contrib/ntfy](contrib/ntfy): desktop `ntfy subscribe` script with a sound
  per pomodoro event
- Tests: `nvim --headless -u NONE -l tests/run.lua`; Go (parser, resolver,
  search, web app, notifications, pomodoro): `go -C app test ./...`

## XP Overview

XP is read off the notes: completed project tasks (a project's pool paid out
over its tasks: a big first step, steady middle, a finishing bonus),
completed tasks anywhere else, and objectives marked `@done` (area XP).
Areas level up over years (`1000 × level^2.5`, 75% of a sub-area's XP counts
for its parent); seasons are date windows over the same awards
(`100 × level^1.2`, Bronze → Master). Unchecking, archiving or editing a note
on your phone simply changes the result. `:ZortexXPExplain` shows how a
project earned its XP. Details: [doc/XP.md](doc/XP.md).

