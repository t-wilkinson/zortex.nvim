# The web app

`zortex serve` shows your notes folder as a website: the notes rendered
with working links, search, a file browser, the calendar, the pomodoro and
other clocks, projects, objectives, areas and the daily and weekly
reviews, and with `-writable` light editing from a phone, the reviews'
fixes included. It reads the same folder Neovim
edits (synced to the server, or on the same machine) and keeps its own
state apart (`-data`).

This page is what the website does and how it works with Neovim. Getting
it running (sync, Docker, NixOS, a login, ntfy) is in
[Server.md](Server.md); every flag and the Go packages are in
[app/README.md](../app/README.md).

- [How it fits with Neovim](#how-it-fits-with-neovim)
- [Pages](#pages)
- [The home page](#the-home-page)
- [Reading notes](#reading-notes)
- [Editing](#editing)
- [Reviews](#reviews)
- [Time tracking](#time-tracking)
- [Slides](#slides)
- [Other calendars](#other-calendars)
- [Installing it as an app](#installing-it-as-an-app)
- [Working with Neovim](#working-with-neovim)
- [API](#api)

## How it fits with Neovim

Neovim and the website share one thing: the notes folder. Neither talks to
the other to read notes; each reads the files.

```
          Neovim ───── edits notes, writes .z/ (XP, state) ─────┐
            │                                                    ▼
            │  /api/notifications, /api/xp, /api/pomodoro, notes folder (synced)
            │  /api/open; GET /api/alerts                        ▲
            ▼                                                    │
     zortex serve ── reads notes; with -writable edits lines, ───┘
        │            writes inbox.zortex, @spent, z/feeds/
        └── -data: notifications, clocks, time tracking, search history
```

| | Neovim | the website |
|---|---|---|
| Notes | the editor; reloads a note changed on disk before editing it | renders them; with `-writable`, line edits checked against what the page saw |
| Calendar notifications | reads them from `calendar.zortex` and sends them on save | keeps them and sends them through ntfy when due |
| Alerts | shows the ones the server raised (`GET /api/alerts`, every `notifications.poll_seconds`) | raises them: calendar notifications, pomodoro phases, timers and alarms |
| Pomodoro | `:ZortexPomodoro`, `<leader>zoo` drive the server's clock | the same clock on the home page |
| XP | computes it; writes `.z/xp_summary.<device>.json`, posts `/api/xp` | shows the summary; counts web completions until Neovim catches up |
| Time | reads `.z/time_spent.json` in the reviews | tracks the clocks' time against a task, writes `@spent` and that file |
| Links | `<leader>zgX` opens the link under the cursor on the website, in the tab you used last | |
| Calendar feeds | shows `z/feeds/*` read-only | fetches them into `z/feeds/`; shows them with their dots |

The details, and the settings, are in [Working with Neovim](#working-with-neovim).

## Pages

| page | what |
|---|---|
| `/` | the home page: the inbox box, the calendar, the clocks, the week's focus, XP, recent notes ([The home page](#the-home-page)) |
| `/graph` | the whole structure as cards side by side, one per section of the Structure note, each note with a `# Structure` section opened in place, and under a note the headings other notes link to (how many notes do); hover a note to mark the notes it links with, click a tag to mark its notes, filter notes and tags as you type (`@word` for tags); the notes not in it |
| `/n/<path>` | a rendered note: outline, every line anchored (`#L12`), links resolved with the plugin's rules (to the canonical target; `⁺` when there are more), broken links in red, file paths and markdown links to the file viewer, [tag tables](#tag-tables) and [indexes](#tag-indexes), its [connections](#connections-and-the-graph), "Linked from" (backlinks) |
| `/n/<path>?view=slides` | the note as a slide deck ([Slides](#slides)) |
| `/search?q=&mode=` | structural search, the plugin's ranking: sections whose path matches the words in order, then lines with every word; `mode=article` names only, `mode=text` lines holding the prompt as typed. Results update as you type, `↑`/`↓` + Enter, `/` focuses search anywhere; with `-data`, what you open ranks higher next time (`search_history.json`). The header's box lists the notes whose name matches as you type; Enter without picking one opens this page |
| `/link?to=&from=` | resolve a link: one target redirects, several are listed (a tag search as a [table](#tag-tables)), failures say why |
| `/f/<path>` | file browser (sort by name (notes by article name) or modified time, either direction: `?sort=modified&order=desc`, kept in folder links; notes with a generated name, like `2026-10-15.042.zortex` from "create note" in search, only with "show all"; hidden folders and Syncthing artefacts never) and viewer: PDF, image, video, audio (with seeking), text, sandboxed HTML/SVG (HTML runs script with `-html-scripts`), [Markdown](#markdown-files) rendered like a note; HTML and Markdown have a "source" link (`?source=1`) to their text. A folder counts the resources under it; `?show=all\|unlinked\|linked&kind=pdf` lists them instead, by folder, folders first (PDFs, books, images, media and documents, and which ones nothing links to). A folder holding only resources (like `z/books`) opens that way; `?list=1` lists its files. The top folder also lists the folders inside `z/` (indented under it), so they are one click away |
| `/raw/<path>` | the file as is: byte ranges, `?download=1`; HTML/SVG/XML with `Content-Security-Policy: sandbox` (`sandbox allow-scripts` for HTML with `-html-scripts`); nothing outside the folder, no hidden files |
| `/tags`, `/tag/<name>` | header tags and their notes (the top bar's Graph lists the tags too); an area attribute in a header (`@area(4.1)`, `@area(1.2/Fitness)`) links to its area (`[A/#4.1]`) |
| `/resources` | redirects to `/f/?show=all` (`?dir=` becomes the path): file pages show their own "Linked from", folder listings count links and unlinked files |
| `/projects` | the week's focus projects (the `Focus:` of the week's entry in `reviews.zortex`), then every project with open work and those without a next action: progress (task `@size` hours, done when a task or its calendar copy is checked), key results, the next task and how often it was put off |
| `/project?rel=&lnum=` | one project: progress, time tracked (all and this week), its next tasks (put off ×n, the day it's planned, due), sub-projects, done tasks, the key results it moves (progress, how far behind its objective's window), its `Log:`, the days it was on the calendar, the notes and files it links and the notes that link it. With `-writable`: tick tasks (calendar copies follow) and add a dated line to its log (`POST /api/project/log` `{rel, lnum, expect, text}`) |
| `/areas` | every area of `areas.zortex`, nested: its vision, its XP (its own and with its sub-areas', its level and the way to the next, from Neovim's XP summary), the objectives running now that name it, the active projects that carry it (their own `@area` or a parent's); the area XP of all areas together at the top. The default area (`xp.default_area`, `0.1`) is marked as where work without one earns |
| `/attributes` | every `@attribute`: how it is written (`@due(2026-10-20)`, `@a(1.2/Fitness)`, …), what it goes on and what it does, with a filter; the same list as Neovim's `:Zortex attributes` (`static/attributes.json`, written from the plugin's `attributes_help.lua`) |
| `/okr` | objectives (`## 3M-2026-Q4 …`) by period; the period of a season shows its name and tier (Neovim's, from the XP summary or its history; for the current quarter without one, estimated here from its objectives' mean progress); a key result with no project and no checkbox is marked stuck: progress (the mean of their key results) against the share of the period gone, marked when behind; each key result with the projects it links; objectives whose period ended without `@done`, later ones, and the latest done |
| `/review?week=` | the weekly review (`:ZortexReview`'s findings): done this week, time tracked, XP and its hours, the inbox, the week's focus (on a weekend, the coming week's) and its entry in `reviews.zortex`, objectives against the time passed, tasks put off on 2+ days, overdue and due in a week, projects without a next action, key results no project moves, the active projects to pick the focus from, time per task; `‹ ›` to other weeks. With `-writable`, its fixes ([Reviews](#reviews)) |
| `/review?day=today` | the daily review (`:ZortexReview day`'s findings) since the last daily review: completed, how the work served the plan, the inbox, the calendar's open tasks, work finished without an area, overdue and due by tomorrow, the week's focus, objectives, time tracked, the day's entry in `reviews.zortex`; `?day=2026-10-21` for another day. With `-writable`, its fixes ([Reviews](#reviews)) |
| `/broken` | links that don't resolve (notes and files), and task ids that don't line up (a project task's `@id` on two lines, a calendar copy whose link points at another task); the notes nothing reaches (not in the structure, and no other note links them; how many more a note links but the structure doesn't) and how many files nothing links to; then the tags that go nowhere: tag searches that find nothing, `[@Tag]` links to a tag no note has, bare tags no tag search asks for |
| `/offline` | the page the installed app shows for a page never opened while offline: the saved pages, and the inbox box ([Installing it as an app](#installing-it-as-an-app)) |
| `/calendar.ics?token=` | the calendar's lines tagged `@share` as an iCal feed for other calendars ([Other calendars](#other-calendars)) |
| `/healthz` (`/health`) | note and link counts, last index time |

Every page has the header's search box (`/` focuses it). The top bar
links the home page (the site's name), Projects, Objectives (`/okr`),
Areas, Review, Files, Broken (only while something is broken) and Graph. Hovering **Files** (or its ▾, on a touch
screen) opens a menu in two columns: the folders under `z/` and the notes
in the top folder with a name of their own (not generated ones like
`2026-10-15.042.zortex`), each a link. The footer links the pages the top
bar doesn't: Search, Tags, Resources, Broken links (with the count),
Attributes, Inbox (with `-writable`), Saved pages and Status
(`/healthz`). Every page's data is also JSON at `/api` + its path
([API](#api)).

## The home page

- **Inbox** (`-writable`): a box that adds a note (the default) or a task
  to the bottom of `inbox.zortex`. It works offline too
  ([Installing it as an app](#installing-it-as-an-app)); the reviews in
  Neovim list the inbox first.
- **Calendar**: the selected day of `calendar.zortex` as written (tasks
  nested under their project's block, a project block's next tasks under
  it, "now" marked on today), with checkboxes when `-writable` (a calendar
  copy ticks its project task too). 🔔 marks a line with a written `@n`.
  Under it the month grid: a dot for days with an `@event`, and a dot in
  its color for each [notifying calendar feed](#other-calendars) with
  events that day. The calendar feeds' events are among the day's lines,
  labelled. **Carry** (`-writable`) moves the open tasks of the last two
  weeks to today, as Neovim's carry forward. The pending notifications and
  the next one are counted above it.
- **Clocks**: the pomodoro (shared with Neovim; its **Settings**), and
  tabs for timers, alarms (once or daily) and a stopwatch. They run on the
  server, so every device sees the same ones and they ring through ntfy
  with no page open. With `-writable` their time goes to a task
  ([Time tracking](#time-tracking)).
- **Focus**: the week's focus projects from the weekly review.
- **Season and XP**: the season's progress on its objectives and its tier,
  its season XP (work on key results), area XP per day for two weeks, top
  areas (all of them on `/areas`) and the area XP of all areas, recent
  awards, from the summary Neovim publishes; tasks ticked on the web with
  their estimated XP until Neovim counts them.
- Recently changed notes, notes not yet in the structure, counts.

## Reading notes

A note page shows the note rendered: its outline, every line anchored
(`#L12`), links resolved with the plugin's rules (`⁺` when a link has more
than one target, broken links in red), file paths and Markdown links to the
file viewer, and "Linked from" at the end. Hover a link (where there is a
mouse; a tap just follows it) for a card: the note's title, path, tags and
first lines, how many links point there; an image link shows the image, a
website its address.

Footnotes link to their line at the bottom of the note and back. A
footnote whose id reads as a citation (`[^Smith, 2020]`, `[^Lee et al.
2019]`) shows as `(Smith, 2020)`, with its reference line as the tooltip
([Footnotes and citations](Syntax.md#footnotes-and-citations)).

**Live updates.** Open pages listen on `/api/events`: a note page redraws
its note when the file changes (an edit in another tab, a note synced from
Neovim), the home page its calendar, XP and pomodoro. Changes made through
Syncthing show up once Syncthing has synced the file: the editing device's
folder watcher waits 10 s by default, so lower `fsWatcherDelayS` on each
device you edit on ([Server](Server.md)). The server sees the file land
right away (inotify on Linux, `-watch`; otherwise the next rescan,
`-poll`, 3 s).

### Connections and the graph

A note page ends with its **connections**: the notes whose structure lists
it (above, with the section they list it under), the notes its own
`# Structure` section lists (below), the other notes it links to (left) and
that link to it (right); `↔` when a link goes both ways. `/graph` is the
whole structure, every hub opened in place once, laid out as a card per
top-level section (the Structure note's loose notes share the first card;
lists more than two levels down start folded, with a count). Beside it are
the header tags (click one to mark its notes) and the notes not in the
structure. The filter box (`/`) hides what doesn't match and opens the
sections that hold matches; `@word` filters by tag; Enter opens the first
match.

### Tag tables

`!@[scope/tags]` on a line of its own renders the lines the tag search finds
as a table (and an `@[…]` link page shows the same table). Columns come from
the lines: the item (attributes left out), its first link and what kind of
thing it is (web, pdf, book, image, video, audio, document, note), its tags
besides the searched ones (its own and its sections'), one column per
`@key(value)` any row has (not `@id`), the note and section it is in, and
its notes: the lines nested under it (labels too), or the section of a
heading that is only a link (`### [Book](https://…) @rust`), shown under
the item: all of them up to three lines, else the first two and an "All
notes" button that opens them in a panel (a bottom sheet on a phone),
rendered like the note, with the first note they link to below them. A
bare `@tag` in a note links to its table (`@[*/tag]`). Click a header to sort; type to filter, or click a kind or
tag to keep only those rows. Empty columns are left out.

### Tag indexes

A label whose lines are all `@[…]` searches, or items grouping them, renders
as rows of chips, each with how many lines its search finds (none: dimmed),
over one shared table ([Syntax](Syntax.md#tag-searches)). Choosing a
chip loads its table (`/api/tagtable?q=&from=`, an HTML fragment) and puts
the search in the address (`#tags=R/rl`); choosing it again clears it, and
the back button undoes it. Nothing is chosen at first. Without script the
chips are links to the search's page.

### Files

**Resources and their backlinks.** A file counts as linked when a note or
a Markdown file refers to it with a zortex link to its path
(`[z/books/type-theory.pdf]`, `[./scan.png]`), a markdown link
(`[TT](z/books/type-theory.pdf)`, `![](img.png)`) or a bare path
(`./scan.pdf`). In notes `./` and `../` are relative to the note and other
paths to the notes folder; Markdown files try their own folder first. A bare
file name (`[type-theory.pdf]`) works when exactly one resource has that
name. Links inside code blocks don't count; links to missing files are
listed on `/broken`. New or removed files are picked up on the next rescan.

<a id="markdown-files"></a>**Markdown files.** A `.md` or `.markdown` file
in the viewer is rendered with the note renderer: headings, lists and tasks,
quotes, tables, footnotes, code blocks, emphasis, `$inline$` and `$$` block
math (KaTeX, as in notes), images (`![alt](img.png)`), inline and reference
links (`[text][id]` with `[id]: url`), `---` rules, setext headings and YAML
front matter (folded). Consecutive lines flow as one paragraph and every line
keeps its `#L12` anchor; headings also get GitHub-style ids
(`other.md#some-heading`). Relative paths resolve from the file's folder
first. Other `[brackets]` are text, not zortex links, and raw HTML is shown
as text: the page is on the app's origin, so nothing in the file runs.

**Math.** `$inline$`, `$$display$$` and `$$` blocks are typeset with
[KaTeX](https://katex.org) on every page (`static/katex`, vendored: loaded
only on pages with math, no CDN).

**Scripts in HTML files (`-html-scripts`, `ZORTEX_HTML_SCRIPTS=1`; NixOS
`web.htmlScripts`).** HTML files are shown without JavaScript by default.
With this on, the file viewer's frame and `/raw` add `allow-scripts` to the
sandbox, but never `allow-same-origin`: the page runs in an opaque origin,
so its script can't read the site's pages, files or cookies, and the
server refuses any POST from a sandboxed page (`Origin: null`), so it can't
edit notes or drive the clocks. It can still do what any web page can:
load things from the internet, and send what it sees there. Turn it on only
for HTML you trust, such as exported notebooks or your own pages. SVG and
XML never run script.

## Editing

With `-writable` (`ZORTEX_WRITABLE=1`; NixOS `web.writable`), note
pages get clickable checkboxes and an Edit mode (the button sits above the
outline on wide screens; tap a line: To-do · Done · Plain · Edit text · Add
below · Move up/down · Delete; drag a line's ⠿ handle to move it, with the
lines indented under it); the home page checks off calendar tasks and adds
tasks and notes to `inbox.zortex`. Editing a line's text (or adding one)
shows chips for the common attributes (`@due(…)`, `@a(…)`, `@size(…)`,
`@p1`, `@project(…)`, `@n(…)`, `@dur(…)`): a tap puts one at the cursor,
the cursor inside its parentheses, and its title says how it is written;
**@ help** opens [`/attributes`](#pages) in a new tab. The inbox box also works offline (in the
installed app, or when the server is down): what you add waits in the
browser and is appended to the bottom of the inbox, in order, when the
connection is back (`app/web/static/inbox.js`). Edits are line-level,
refused when the note changed since the page loaded, and written
atomically (through a `.syncthing.*.tmp` file Syncthing ignores). Task
edits match Neovim's exactly: `app/edit` is tested against
`tests/fixtures/edits.json`, which `tests/gen_edits.lua` writes from the
plugin's `tasks.edit_line`. XP isn't computed on the server: Neovim counts
completed tasks from their `@done` dates when it next runs (it reloads
changed notes on focus), and until then the home page shows how many web
completions are waiting.

## Reviews

`/review?day=today` and `/review` are Neovim's daily and weekly reviews
(`:ZortexReview day`, `:ZortexReview`), to do on a phone. They read the
same notes and write the same lines, so a review done on the web is done:

- **The window.** The daily review covers the days since the last daily
  review (at most a week back), from `.z/review_state.json`, which Neovim
  and the web share; **Finish review** marks the day reviewed there, and
  Neovim's next daily review starts after it (and the other way round).
- **Tick** (`x`): a task's checkbox, as the note page does (copies follow).
- **→ Tomorrow** (`t`): an open calendar task goes on the next day at the
  same time, `[>]` on the old line (made from the calendar's template when
  the day is new).
- **Due…** (`d`): sets or moves `@due` (`2026-10-21`, `+3`, `tomorrow`).
- **Move** (`m`): an inbox line, with the lines indented under it, goes to
  the end of the project picked (the line's `@project(…)` picked for you),
  without `@project`.
- **Give it an area** (`A`): finished work without an area gets `@a(…)`: a
  project on its heading (its tasks listed under it), a loose task on its
  line. **Finish review** writes `@a(0.1)` (Neovim's `xp.default_area`,
  from its summary) on what is still without one, when `areas.zortex` has
  that area ([Planning](Planning.md#area-xp-and-season-xp)).
- **+ Focus / − Focus** (`f`, weekly): the project in or out of the
  week's `Focus:` (on a weekend, the coming week's, as Neovim plans it).
- **Write a line** under a label of the entry (`Done:`, `Blocked:`, `Wins:`,
  …): the day's or the week's entry in `reviews.zortex`, made from the
  note's `# Templates` when missing, the label added when it has none.

Each fix names the line it expects: when the note changed since the page
loaded (Neovim, Syncthing), nothing is written and the page says to reload.
After a fix the page reloads where it was.

## Time tracking

With `-writable` (and `-data`), the clock box on the home page has a
**Working on** line: the task the clocks' time goes to.

- **Which task.** By default the current calendar entry: the timed entry of
  today that has started (and not ended, for `09:00 - 10:30` ranges). When
  tasks are nested under it (`09:00 [P/#1.4 - zortex]` with
  `  - [ ] [./-Improve website] @id(…)` below), the first open one: tick it
  and the time goes to the next. Otherwise, when its first link points at a
  task (`[P/#1.4 - zortex/-Improve website]`), that task; otherwise the
  calendar line itself. It changes when the next
  entry starts. **Change** picks another (search open tasks), as does
  **⏱ Track** in a note's Edit toolbar; then the calendar no longer
  matters until you choose **Follow the calendar** (or **Don't track**).
- **What counts.** Time while any clock runs: a pomodoro *work* phase, the
  stopwatch, a timer. Overlapping clocks count once; breaks and pauses
  don't count.
- **When it's written.** When the clocks stop (pause, the end of a work
  phase, a timer done) the time is added to the task's `@spent(1h25m)`,
  rounded to minutes. Under a minute nothing is written: it waits for more
  on the same task, and is dropped when the task changes. Changing the task
  while a clock runs closes the old task's account and starts the new one
  from zero.
- The task is found again by its `@id`, else by its text (nearest to where
  it was). Each write is logged to `-data/track_log.jsonl`. Neovim reads
  `@spent` as a duration (minutes), like `@dur`.

## Slides

`/n/<path>?view=slides` (the **slides** link on a note page, or
`:ZortexPresent` in Neovim) shows a note as a slide deck. Nothing in the
note has to change:

| in the note | on the slides |
|---|---|
| `@@Name` and the lines before the first heading | the title slide |
| headings at the slide level | one slide each, with everything up to the next one |
| headings above the slide level | section slides |
| `Notes:` (or `**Notes:**`) in a slide | speaker notes: hidden, shown in the presenter window |
| `@step` on a line | revealed on its own click, with the lines nested under it |
| `@steps` on a slide's heading | each of its top-level items revealed in turn |
| `---` | a new slide that carries on the one before it, under the same heading (a note without headings is cut into slides by its rules) |
| `@slides(n)` in the header | headings of level n start the slides |

The slide level is `@slides(n)`, or else the second heading level the note
uses (with `#` and `##`, `##` are slides and `#` section slides), or the only
one. Attributes are hidden on slides; links, tasks, tables, code, math and
images and videos (`![./pic.png]`, `![./clip.mp4]`; a video pauses when you leave its slide) render as on the note page, and a slide whose text
doesn't fit is shrunk until it does.

Keys: `→` `Space` `PgDn` next, `←` `PgUp` previous, `Home`/`End`, a number
and `Enter` to jump, `o` overview, `s` presenter window (current slide, next
slide, notes, a timer: click pauses, double-click resets; it and the deck
follow each other), `f` fullscreen, `b` black screen, `?` the keys. Swipe on
a phone. The hash is the position (`#3`, `#3.2` for its second step; `#L42`
opens the slide holding line 42), a link to a line of the note goes to its
slide, and the deck redraws in place when the note is saved. Printing
(Ctrl+P) gives one 16:9 page per slide.

## Other calendars

The server can fetch other calendars (a Cozi family member's, Google's,
Apple's: any iCal link) into your notes, and publish your calendar's
`@share` lines for them to subscribe to. Setting it up is in
[Server.md](Server.md#6-other-calendars). On the website:

- a feed's events are among the day's lines on the home page, read-only,
  labelled with the feed's name;
- a feed with `notify` on gets a dot of its own on the month grid, on the
  days it has events, in its `color` (default orange), beside the dot for
  your `@event`s; its label carries the same dot;
- `/calendar.ics` serves the lines you tagged `@share` (30 days back to 180
  ahead); with `-share-token-file`, `?token=…` gets in without the login.

Neovim shows the same events in its calendar, planner and agenda.

## Installing it as an app

The web app is installable (a PWA): on a phone, open it in the browser and
choose **Add to Home Screen** (Safari) or **Install app** (Chrome); on the
desktop, the install button in Chrome's or Edge's address bar. It opens in
its own window, without the browser's bars, at the home page; long-pressing
the icon offers Search and Projects (and Add to inbox with `-writable`). Browsers allow this over HTTPS only
(and on `localhost`), so serve it as in [Server.md](Server.md#3-put-it-behind-a-login).

Recent pages read offline. The app keeps the last 60 pages you opened on
the device, so when the phone is offline or the server can't be reached, a
page you read lately opens as a saved copy (it says when it was saved), and
any other page shows the list of saved ones. Editing, the clocks and live
updates need the server.

The inbox works offline. With `-writable`, the inbox box on the home page
(and on the offline page) keeps what you add while there is no connection,
or while the server is down, and appends it to the bottom of
`inbox.zortex`, in the order you added it, as soon as the server can be
reached again (when the app is next open: on reconnecting, on returning to
it, or within 30 seconds). It says how many are waiting. A capture whose
answer was lost on a flaky connection is sent again but added once. The copies live in the browser's storage on that
device, behind the device's own lock; clearing the site's data removes
them, and each new version of the server starts afresh.

Behind a login: the manifest (`/manifest.webmanifest`) and the icons
(`/static/icons/`) hold the site's title and nothing from your notes, and a
phone's installer may fetch them without your credentials. `-auth-file`
serves them without a login; with a proxy's login, let those two paths
through too (with `-base`, below the prefix):

```
notes.example.com {
  @app path /manifest.webmanifest /static/icons/*
  handle @app {
    reverse_proxy 127.0.0.1:8090
  }
  handle {
    basic_auth {
      me $2a$14$...
    }
    reverse_proxy 127.0.0.1:8090
  }
}
```

## Working with Neovim

The plugin expects the server (`server.enabled` is true by default); tell
it where:

```lua
require("zortex").setup({
  server = {
    api_endpoint = "https://notes.example.com", -- or http://127.0.0.1:8090
    api_key = os.getenv("ZORTEX_API_KEY"),        -- the server's -api-key, if set
    web_url = nil,  -- where the browser reaches the website, when not api_endpoint
  },
})
```

Neovim's requests carry `X-API-Key`, which also passes `-auth-file`'s
login. What each side does:

- **Notifications.** Saving `calendar.zortex` sends its notifications to
  the server (`POST /api/notifications/sync`; an unchanged calendar isn't re-sent,
  `:ZortexNotifications sync force` resends). The server sends each
  through ntfy when it is due, whether Neovim is running or not. The
  calendar feeds' events are among them when their feed notifies.
  `:ZortexNotifications list` shows what is waiting, `send <title>
  <message>` sends one now.
- **Alerts.** What the server announces (a calendar notification, a
  pomodoro phase, a timer or an alarm) is also kept for Neovim, which asks
  for the new ones every `notifications.poll_seconds` (`GET /api/alerts`)
  and shows them (`notifications.alerts = false` doesn't).
- **Pomodoro.** `:ZortexPomodoro` (`toggle`, `skip`, `restart`, `stop`,
  `status`, `settings work=50 short=10 …`) and `<leader>zo…` drive the
  server's clock (`/api/pomodoro/*`), the one on the home page; the
  settings live on the server, changed from either side.
- **XP.** Neovim computes XP from the notes and publishes a summary after
  every change: `.z/xp_summary.<device>.json` in the notes folder (synced) and
  `POST /api/xp`; the website shows the newest. With XP off
  (`xp.enabled = false` in Neovim, `-xp=false` on the server) neither side
  shows it.
  Tasks ticked on the website are counted by Neovim from their `@done`
  date the next time it runs; meanwhile the home page shows them with their
  estimated XP (`pending_web`).
- **Edits from the website.** They are written to the files, so Neovim
  sees them like any synced change: a note open in Neovim is reloaded
  (`:checktime`) before Neovim edits it, and an edit is refused when the
  lines around it changed since they were read. Task edits are the same on
  both sides (`app/edit` is tested against the plugin's own output,
  `tests/fixtures/edits.json`).
- **Time.** The website's time tracking adds `@spent(…)` to the task and
  records it per day in `.z/time_spent.json`, which Neovim's reviews read.
- **Carry forward.** The home page's **Carry** and Neovim's
  `:ZortexCarryForward` (and the planner on opening today) do the same
  thing: open tasks of earlier days copied to today with the same `@id`,
  the old lines marked `[>]`.
- **Presenting.** `:ZortexPresent` (`<leader>zS`) opens the note as
  [slides](#slides), at the slide under the cursor.
- **Calendar feeds.** The server writes `z/feeds/<name>.zortex`; Neovim
  shows those events read-only (`features.calendar_feeds` hides a feed in
  Neovim only).

### Opening pages from Neovim

`:ZortexLinkOpenWeb` (`<leader>zgX`) shows the link under the cursor in the
web app: zortex links and tag searches through `/link`, files in the
viewer, a tag index with the line's chip chosen, else the note at the
cursor's line (`gx` on an index's label does it too). With `server.enabled`
the page goes to the tab on the same device that was focused last, instead
of a new tab:

- each page opens `/api/events?client=<id>` (one id per tab) and posts
  `/api/presence` when it's focused;
- Neovim posts `{"path": "/n/x.zortex#L3"}` to `/api/open`; the server sends
  it to that tab, which answers `/api/open/ack` and goes there;
  `{"opened": true}` then, `{"opened": false}` after 2 s or with no tab, and
  Neovim opens a new one.

`:ZortexOpenWeb` (`<leader>zW`) opens the note you're in, at the cursor's
line, whatever is under the cursor (another file in the notes folder opens
in the viewer); it saves the buffer first, so the page shows what you see.

"Same device" is the same client address: behind a proxy on the server's
machine or network, its `X-Forwarded-For`. A page can change what it shows
but not raise its window. `features.web.reuse_tab = false` always opens a
new tab.

## API

Everything the pages use is plain HTTP with JSON, under `/api/`:

- **Pages as data.** Every page with data has it at `/api` + its path, same
  query: `/api/projects`, `/api/project?rel=&lnum=`, `/api/okr`,
  `/api/areas`, `/api/review?day=today`, `/api/review?week=2026-W43`,
  `/api/broken`, `/api/tags`, `/api/tag/<name>`, `/api/attributes`,
  `/api/f/<folder>` (a note's path there redirects to `/api/n/<path>`).
  It is what the page shows, keys in snake_case, without the top bar's.
- **Notes** are `/api/n/<path>`: `GET` renders one, `POST` edits it.
- **Replies.** A failure is `{"error": "…"}` with a 4xx or 5xx status (an
  unknown `/api/` path too); a write that has nothing else to say answers
  `{"ok": true}`.
- **Keys.** `X-API-Key` (Neovim's `server.api_key`) is needed for
  `/api/notifications…`, `/api/alerts` and `POST /api/xp` when `-api-key` is
  set; with `-auth-file`, every endpoint but `/healthz` (and `/calendar.ics`
  with its token) needs the login or the key. POSTs must be JSON (or carry
  the key), so a cross-site form can't make them.

| endpoint | |
|---|---|
| `GET /api/<page>` | a page's data (above) |
| `GET /api/n/<path>` | a rendered note: `{rel, title, body, mod, src?}` (`src`, each line's text and where its content starts, with `-writable`) |
| `POST /api/n/<path>` | `-writable` only: `{lnum, expect, op, text?, kind?}` with `op` `open` / `done` / `toggle` / `text` (task state, exactly as Neovim's toggle: `@done(today)`, an `@id`), `set` (new text after the line's marker; `@id`/`@done` kept), `delete`, `insert` (after `lnum`; `kind` `task` / `note` / `text`), `move` (the line and the lines indented under it go before line `to`, `len+1` for the end, re-indented to fit; `expectTo` is that line's text). `expect` is the line as the page saw it: if the note changed since, nothing is written and the reply is 409 with the current note. Task ops keep copies in step: the other lines with the task's `@id` in the calendar and the project notes get the same state (not `[>]` lines), and on a calendar line without a checkbox whose link points at a task they toggle that task (the reply then carries `task: {rel, lnum, line}`) |
| `GET /api/search?q=&mode=` | structural search results |
| `GET /api/link?to=&from=` | what a link resolves to (the page is `/link`) |
| `GET /api/backlinks?rel=` | the lines that link a note |
| `GET /api/hover?rel=&lnum=` | a link's hover card: the note's title, path, header tags, first lines (a heading's own lines) and how many links point there; images and websites need no call (the card shows the image, or the domain and URL; nothing is fetched) |
| `GET /api/resources?show=unlinked&kind=&dir=` | resources and what links them |
| `GET /api/tagtable?q=&from=` | a tag search's table, as HTML ([tag indexes](#tag-indexes)) |
| `GET /api/graph` | the Structure note's notes, and those not in it (the page is `/graph`) |
| `GET /search/open?rel=&lnum=` | open a search result (`&section=1` for a section) and count it in the search history (with `-data`) |
| `GET /api/calendar?from=&to=` | `days` (entries of `calendar.zortex` with time, text, rendered HTML, task state, whether a notification is scheduled; the calendar feeds' events among them, with `feed` and no `rel`; the `# Repeating` rules' occurrences, with `repeat`), `notifications`, `count`, `next_event`, `carry`, `feeds` (`name`, `title`, `notify`, and for a notifying feed its dot `color`) |
| `POST /api/calendar/repeat` | `-writable` only: `{lnum, expect, date}`: tick the occurrence on `date` of the repeating task on line `lnum` of the calendar's `# Repeating` section (`expect`: that line): a done copy goes into today (made from its template when new), with `@for(date)` when it was due another day. `GET /api/calendar`'s days list the occurrences with `repeat`, `date`, and `copy` (the copy's line, then `lnum` and `src` are the copy's and `POST /api/n/…` toggles it) |
| `POST /api/calendar/carry` | `-writable` only: `{date?}` (default today): copy the open tasks of the 14 days before to the date with the same `@id` and mark the old lines `[>]`, as Neovim's `:ZortexCarryForward`; `{moved, added}`. `GET /api/calendar` has `carry`, how many there are for today (the home page offers a **Carry** button) |
| `GET /api/notifications?user_id=` | the pending notifications, soonest first: `{count, notifications}` |
| `POST /api/notifications` | `{user_id, notification}` adds one: `{ok, id, duplicate}` |
| `POST /api/notifications/sync` | `{user_id, notifications: [...]}` replaces the user's pending notifications (unchanged ones keep their identity; an identical list is a no-op): `{ok, added, updated, removed, unchanged}` |
| `POST /api/notifications/clear` | `{user_id}` removes the pending ones: `{ok, deleted}` |
| `POST /api/notifications/test` | `{title?, message?}`: publish through ntfy now: `{ok}` |
| `GET /api/alerts?after=` | the alerts raised after `seq` `after` (calendar, pomodoro, clocks; the last 100): `{seq, alerts: [{seq, kind, title, message, at}]}`; without `after`, only the current `seq` |
| `GET /api/summary` | for home dashboards (Homepage, Home Assistant, …): `{generated, pending, next, text, html, pomodoro?, xp?: {today, week, season: {name, progress, tier, xp}}}` |
| `POST /api/inbox` | `-writable` only: `{text, kind: "task" \| "note", id?}` appended to the bottom of `inbox.zortex` (created when missing). `id` is set by the offline queue: a capture sent again with the same id (its answer was lost) is added once |
| `POST /api/project/log` | `-writable` only: `{rel, lnum, expect, text}`: a dated line in the project's `Log:` |
| `POST /api/review/note` | `-writable` only: `{week, date?, label, text}`: `- text` under the label of the week's entry (or the day's, with `date`) in `reviews.zortex`, made from its template when missing; `{rel, lnum, url}` |
| `POST /api/review/focus` | `-writable` only: `{week, rel, lnum}`: the project (its heading) in or out of the week's `Focus:`; `{added, project}` |
| `POST /api/review/move` | `-writable` only: `{rel, lnum, expect, to: "rel:lnum"}`: the line and the lines under it, without `@project`, to the end of that project's own lines |
| `POST /api/review/tomorrow` | `-writable` only: `{lnum, expect}`: the open calendar task on that line to the next day, same time, `[>]` on the old line; `{date}` |
| `POST /api/review/due` | `-writable` only: `{rel, lnum, expect, due}` (`YYYY-MM-DD`, `+N`, `tomorrow`): sets `@due` |
| `POST /api/review/area` | `-writable` only: `{rel, lnum, expect, area}`: `@a(area)` on the line (any other `@area`/`@a` replaced); the area must exist in `areas.zortex` |
| `POST /api/review/finish` | `-writable` only: `{date?}`: `@a(<default area>)` on the finished work of the daily review's window still without an area, and the day marked reviewed in `.z/review_state.json`; `{stamped, area, date}` |
| `GET /api/pomodoro` | phase, running, remaining, ends_at, session, completed, today, settings, `next_alarm`, `ntfy` |
| `POST /api/pomodoro/{start,pause,resume,toggle,skip,stop,restart}` | drive the clock |
| `POST /api/pomodoro/settings` | `{work, short_break, long_break, long_break_after, auto_start_break, auto_start_work}` (minutes; partial updates are fine) |
| `GET /api/clocks` | timers, alarms and the stopwatch: `{timers, alarms, stopwatch, now, ntfy}` |
| `POST /api/clocks/timers` | `{label, seconds}` starts a timer; `POST /api/clocks/timers/{id}/{pause,resume,restart,remove}` |
| `POST /api/clocks/alarms` | `{label, time: "HH:MM", repeat: "once" \| "daily"}`; `POST /api/clocks/alarms/{id}/{enable,disable,remove}` |
| `POST /api/clocks/stopwatch/{start,pause,toggle,lap,reset}` | the stopwatch |
| `GET /api/track` | time tracking: `{enabled, mode: calendar \| pinned \| off, task, counting, counted_ms, calendar?, error}` |
| `POST /api/track/pin` | `{rel, lnum, expect?}` work on this line; `POST /api/track/{follow,off,flush}`; `GET /api/track/tasks?q=` open tasks for the picker |
| `GET /api/xp` | the XP summary Neovim published (version 3: the season with its `season_xp`; `daily` area XP for 14 days and `days`, 60 days of area, season and work XP and how the work served the plan; the top `areas`, every area in `area_tree` and their `area_total`; recent awards with their area and season XP; the calibration, with `default_area`), or `{"available": false}`; plus `pending_web` (tasks completed on the web since, one per `@id`), `pending_xp` and `pending_tasks` (`{title, xp, hours}`: estimated from the task's `@size`, priority and importance with the summary's calibration) |
| `POST /api/xp` | Neovim publishes it after every XP change (`X-API-Key` when set); it also writes `.z/xp_summary.<device>.json` into the notes folder, and the newest of them is shown |
| `GET /api/events` | server-sent events for open pages: `notes` (`{rels}` added, changed or removed; seen as the file lands, or on the next rescan, `-poll`), `xp` (a new summary), `pomodoro` (the clock changed), `clocks` (timers, alarms, stopwatch), `track` (time tracking). Pages redraw right away; behind nginx the stream needs `proxy_buffering off` (the server also sends `X-Accel-Buffering: no`) |
| `POST /api/open`, `/api/presence`, `/api/open/ack` | show a page in an open tab ([from Neovim](#opening-pages-from-neovim)) |

Notifications more than 2 h overdue (server down) are
skipped rather than sent late; sent ones are kept a week.

**Pomodoro events** (ntfy tags): `pomodoro-work-start`,
`pomodoro-break-start`, `pomodoro-restart` (back to work after the long
break, or Restart cycle), `pomodoro-work-end` / `pomodoro-break-end` (the next
phase waits for you when auto-start is off), `pomodoro-stop`. Timers carry
`timer`, alarms `alarm`. A timer or alarm that came due while the server was
down is sent when it starts again if it is under 10 minutes late.
