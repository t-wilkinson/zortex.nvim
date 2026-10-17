# Zortex app

The server side of Zortex: **`zortex serve`**, one Go binary with no
dependencies (this folder's Go module).

- **Notes**: rendered notes with working links and backlinks,
  structural search, a browser for every file in the folder (PDFs, images,
  media, text), tags, broken links, and the notes not yet linked from the
  Structure note.
- **Calendar** (home page): the days of `calendar.zortex` and the
  notifications Neovim schedules from it (`POST /notify`). Due notifications
  are sent through **ntfy** by the server itself (no cron, no database).
- **Pomodoro**: a clock owned by the server, driven from the home page and
  from Neovim (`:ZortexPomodoro…`, `<leader>zoo`). Phase changes go out
  through ntfy, each with its own tag so the desktop can play a different
  sound for starting work, starting a break and starting a new cycle
  ([`../contrib/ntfy`](../contrib/ntfy)).
- **Timer, alarm, stopwatch**: tabs next to the pomodoro on the home page.
  Timers and alarms (once or every day, at a time of day on the server's
  clock) ring through ntfy whether or not a page is open; every device sees
  the same ones.
- **Time tracking** (`-writable`): while a clock runs, its time goes to the
  task you're working on (the current calendar entry by default) and is
  added to the task's `@spent(...)`. See [Time tracking](#time-tracking).
- **Digest**: `GET /api/digest` gives the coming days of the calendar as a
  subject, text and HTML, for whatever mail or chat service you use.

Notes are read-only unless `-writable` is set. The server's own state
(`notifications.json`, `pomodoro.json`, `clocks.json`, `track.json` and
`track_log.jsonl`, the XP summary)
lives in `-data`. Without `-data` it serves the notes only. The server never
creates notes of its own except `inbox.zortex` (web edits); Neovim's
`setup()` creates the key notes in a new folder.

## Quick start

```sh
go -C app run ./cmd/zortex serve -dir ~/notes -data ~/.local/state/zortex \
  -ntfy-url https://ntfy.sh -ntfy-topic my-zortex-topic        # http://127.0.0.1:8090/
docker compose -f app/docker-compose.yml up -d                  # NOTES_PATH, NTFY_* in app/.env
```

Neovim:

```lua
require("zortex").setup({
  server = { enabled = true, api_endpoint = "http://127.0.0.1:8090", user_id = "me" },
  -- with ntfy enabled here too, pomodoro alerts go only through ntfy
})
```

## Web app: `zortex serve`

```sh
go -C app run ./cmd/zortex serve -dir ~/notes            # http://127.0.0.1:8090/
nix run .#zortex -- serve -dir ~/notes -addr 0.0.0.0:8090
```

| page | what |
|---|---|
| `/` | search box, the **calendar** (days of `calendar.zortex`, a month grid whose dot marks days with an `@event`, scheduled notifications; 🔔 on lines with a written `@n`), the **pomodoro** clock with **timer**, **alarm** and **stopwatch** tabs, **this week's focus projects**, **season and XP** (level and tier, progress to the next level, XP per day for two weeks, top areas, recent awards; tasks completed on the web with their estimated XP until Neovim counts them), recently changed notes, notes not yet in the structure, counts |
| `/structure` | notes that neither the Structure note (`@@Structure`), any `@Structure` note, nor any note's `# Structure` section links to (archived notes left out); not in the top bar, since `/graph` lists the same notes |
| `/graph` | the whole structure as cards side by side, one per section of the Structure note, each note with a `# Structure` section opened in place, and under a note the headings other notes link to (how many notes do); hover a note to mark the notes it links with, click a tag to mark its notes, filter notes and tags as you type (`@word` for tags); the notes not in it |
| `/n/<path>` | a rendered note: outline, every line anchored (`#L12`), links resolved with the plugin's rules (to the canonical target; `⁺` when there are more), broken links in red, file paths and markdown links to the file viewer, [tag tables](#tag-tables) and [indexes](#tag-indexes), its [connections](#connections-and-the-graph), "Linked from" (backlinks) |
| `/n/<path>?view=slides` | the note as a slide deck ([Slides](#slides)) |
| `/search?q=&mode=` | structural search, the plugin's ranking: sections whose path matches the words in order, then lines with every word; `mode=article` names only, `mode=text` lines holding the prompt as typed. Results update as you type, `↑`/`↓` + Enter, `/` focuses search anywhere; with `-data`, what you open ranks higher next time (`search_history.json`). The header's box lists the notes whose name matches as you type; Enter without picking one opens this page |
| `/link?to=&from=` | resolve a link: one target redirects, several are listed (a tag search as a [table](#tag-tables)), failures say why |
| `/f/<path>` | file browser (sort by name (notes by article name) or modified time, either direction: `?sort=modified&order=desc`, kept in folder links; notes with a generated name, like `2026-10-15.042.zortex` from "create note" in search, only with "show all"; hidden folders and Syncthing artefacts never) and viewer: PDF, image, video, audio (with seeking), text, sandboxed HTML/SVG (HTML runs script with `-html-scripts`), [Markdown](#markdown-files) rendered like a note; HTML and Markdown have a "source" link (`?source=1`) to their text |
| `/raw/<path>` | the file as is: byte ranges, `?download=1`; HTML/SVG/XML with `Content-Security-Policy: sandbox` (`sandbox allow-scripts` for HTML with `-html-scripts`); nothing outside the folder, no hidden files |
| `/tags`, `/tag/<name>` | header tags and their notes (the top bar's Graph lists the tags too); an area attribute in a header (`@area(4.1)`, `@a(1.2/Fitness)`) links to its area (`[A/#4.1]`) |
| `/resources` | PDFs, books, images, media and documents, and which ones nothing links to (all by default; filter by unlinked/linked, type, folder); file pages show their own "Linked from", folder listings count links and unlinked files |
| `/projects` | the week's focus projects (the `Focus:` of the week's entry in `reviews.zortex`), then every project with open work and those without a next action: progress (task `@size` hours, done when a task or its calendar copy is checked), key results, the next task and how often it was put off |
| `/project?rel=&lnum=` | one project: progress, time tracked (all and this week), its next tasks (put off ×n, the day it's planned, due), sub-projects, done tasks, the key results it moves (progress, how far behind its objective's window), its `Log:`, the days it was on the calendar, the notes and files it links and the notes that link it. With `-writable`: tick tasks (calendar copies follow) and add a dated line to its log (`POST /api/project/log` `{rel, lnum, expect, text}`) |
| `/okr` | objectives by period (`## 3M-2026-Q4 …`): progress (the mean of their key results) against the share of the period gone, marked when behind; each key result with the projects it links; objectives whose period ended without `@done`, later ones, and the latest done |
| `/review?week=` | the weekly review (`:ZortexReview`'s findings), read-only: done this week, time tracked, XP and its hours, the inbox, the week's focus, objectives against the time passed, tasks put off on 2+ days, overdue and due in a week, projects without a next action, key results no project moves, time per task; `‹ ›` to other weeks |
| `/broken` | links that don't resolve (notes and files), and task ids that don't line up (a project task's `@id` on two lines, a calendar copy whose link points at another task); then the tags that go nowhere: tag searches that find nothing, `[@Tag]` links to a tag no note has, bare tags no tag search asks for |
| `/api/search?q=`, `/api/resolve?to=&from=`, `/api/backlinks?rel=`, `/api/resources?show=unlinked&kind=&dir=`, `/api/structure` | JSON |
| `/api/hover?rel=&lnum=` | a link's hover card: the note's title, path, header tags, first lines (a heading's own lines) and how many links point there; images and websites need no call (the card shows the image, or the domain and URL; nothing is fetched) |
| `/api/tagtable?q=&from=` | a tag search's table, as HTML ([tag indexes](#tag-indexes)) |
| `POST /api/open`, `/api/presence`, `/api/open/ack` | show a page in an open tab ([from Neovim](#opening-pages-from-neovim)) |
| `/manifest.webmanifest`, `/sw.js`, `/offline` | the installable app: its manifest (no login needed, nor for `/static/icons/`), the service worker (recent pages kept for reading offline), and the page shown offline for a page never opened ([Installing it as an app](../doc/Server.md#installing-it-as-an-app)) |
| `/healthz` (`/health`) | counts and last index time |

Flags (each also an environment variable): `-dir` (`ZORTEX_NOTES_DIR`),
`-addr` (`ZORTEX_ADDR`, default `127.0.0.1:8090`), `-base` (`ZORTEX_BASE`:
the URL prefix when a proxy serves it below `/`, e.g. `/notes`), `-title`
(`ZORTEX_TITLE`), `-poll` (`ZORTEX_POLL`, default `3s`), `-resources` (`ZORTEX_RESOURCES`: extensions tracked as resources; NixOS:
`web.resourceExtensions`).

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

**How it stays light.** The folder is read once at start and rescanned every
`-poll`. A rescan re-parses only files whose modification time or size
changed; when anything changed, the search index, backlinks, tags and broken
links are rebuilt in the background and swapped in. Notes keep their text,
section tree and a compact per-line summary; a page re-parses the one note it
shows. Measured on 2,000 generated notes (16 MB, 64,000 links): first index
about 2 s, rebuild about 2.5 s, search 30–60 ms, a note page 5 ms, about
120 MB resident with `GOMEMLIMIT=120MiB` (a typical folder is far smaller).
There is no login: bind to localhost and put a proxy with authentication in
front.

**Editing (`-writable`, `ZORTEX_WRITABLE=1`; NixOS `web.writable`).** Note
pages get clickable checkboxes and an Edit mode (the button sits above the
outline on wide screens; tap a line: To-do · Done · Plain · Edit text · Add
below · Move up/down · Delete; drag a line's ⠿ handle to move it, with the
lines indented under it); the home page checks off calendar tasks and adds
tasks and notes to `inbox.zortex`. Edits are line-level, refused when the note changed since the page loaded, and written
atomically (through a `.syncthing.*.tmp` file Syncthing ignores). Task
edits match Neovim's exactly: `app/edit` is tested against
`tests/fixtures/edits.json`, which `tests/gen_edits.lua` writes from the
plugin's `tasks.edit_line`. XP isn't computed on the server: Neovim counts
completed tasks from their `@done` dates when it next runs (it reloads
changed notes on focus), and until then the home page shows how many web
completions are waiting.

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

**Live updates.** Open pages listen on `/api/events`: a note page redraws
its note when the file changes (an edit in another tab, a note synced from
Neovim), the home page its calendar, XP and pomodoro. Changes made through
Syncthing show up after Syncthing has synced the file (its folder watcher
waits 10 s by default: lower `fsWatcherDelayS` for faster updates) and
the server's next rescan (`-poll`, 3 s).

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
over one shared table ([Syntax](../doc/Syntax.md#tag-searches)). Choosing a
chip loads its table (`/api/tagtable?q=&from=`, an HTML fragment) and puts
the search in the address (`#tags=R/rl`); choosing it again clears it, and
the back button undoes it. Nothing is chosen at first. Without script the
chips are links to the search's page.

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

"Same device" is the same client address: behind a proxy on the server's
machine or network, its `X-Forwarded-For`. A page can change what it shows
but not raise its window. `features.web.reuse_tab = false` always opens a
new tab.

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

### Slides

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

**Math.** `$inline$`, `$$display$$` and `$$` blocks are typeset with
[KaTeX](https://katex.org) on every page (`static/katex`, vendored: loaded
only on pages with math, no CDN).

### Time tracking

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

**Login.** There is none by default: keep the server on `127.0.0.1` and
publish it through a proxy that has one (doc/Server.md). Without such a
proxy, `-auth-file FILE` (`ZORTEX_AUTH_FILE`; or `ZORTEX_AUTH=user:password`;
NixOS `web.authFile`) asks for a login (HTTP basic auth) on every page and
endpoint except `/healthz`; requests with a valid `X-API-Key` (Neovim) pass.
The file has `user:password` lines. Use it over HTTPS. Listening on anything
but localhost without a login logs a warning.

State flags (with `-data`): `-data` (`ZORTEX_DATA_DIR`, or systemd's
`STATE_DIRECTORY`), `-ntfy-url` (`NTFY_SERVER_URL`), `-ntfy-topic`
(`NTFY_TOPIC`), `-ntfy-token` (`NTFY_AUTH_TOKEN`) or `-ntfy-token-file`,
`-api-key` (`ZORTEX_API_KEY`), `-send-interval` (default `20s`).

### NixOS

```nix
{
  imports = [ zortex.nixosModules.default ];
  services.zortex = {
    enable = true;                       # zortex-web.service on 127.0.0.1:8090
    notesDir = "/var/lib/syncthing/zortex";
    notesGroup = "syncthing";            # read access to the synced folder
    ntfy = {
      url = "https://ntfy.home.lab";
      topic = "zortex";
      authTokenFile = "/run/secrets/ntfy-token";
    };
    # apiKeyFile = "/run/secrets/zortex-api";   # ZORTEX_API_KEY=...
    # web.basePath = "/notes";                   # when proxied below "/"
  };

  services.nginx.virtualHosts."zortex.home.lab" = {
    locations."/".proxyPass = "http://127.0.0.1:8090";
    basicAuthFile = "/run/secrets/zortex-htpasswd";
  };
}
```

Everything is one service on `web.port`. It runs as the `zortex` user with
read-only access to `notesDir`, a writable `dataDir` (`/var/lib/zortex`) and
the usual systemd hardening.

## Notification and pomodoro API

| endpoint | |
|---|---|
| `POST /notify` | `{user_id, operation: "sync", notifications: [...]}` replaces the user's pending notifications (unchanged ones keep their identity; an identical manifest is a no-op: `{unchanged: true}`); `operation: "notify"` adds one; `"clear"` removes the pending ones |
| `GET /pending?user_id=` | pending notifications |
| `POST /test` | `{title?, message?}`: publish through ntfy now and report |
| `GET /api/calendar?from=&to=` | `days` (entries of `calendar.zortex` with time, text, rendered HTML, task state, whether a notification is scheduled), `notifications`, `count`, `next_event` |
| `GET /api/summary` | for homelab dashboards: pending count, upcoming notifications as text/HTML, the pomodoro |
| `GET /api/pomodoro` | phase, running, remaining, ends_at, session, completed, today, settings, `next_alarm`, `ntfy` |
| `POST /api/pomodoro/{start,pause,resume,toggle,skip,stop,restart}` | drive the clock |
| `GET /api/xp` | the XP summary Neovim published (season, daily XP, areas, recent awards, calibration), or `{"available": false}`; plus `pending_web` (tasks completed on the web since, one per `@id`), `pending_xp` and `pending_tasks` (`{title, xp, hours}`: estimated from the task's `@size`, priority and importance with the summary's calibration) |
| `POST /api/xp` | Neovim publishes it after every XP change (`X-API-Key` when set); it also writes `.z/xp_summary.json` into the notes folder, and the newer of the two is shown |
| `POST /api/edit` | `-writable` only: `{rel, lnum, expect, op, text?, kind?}` with `op` `open` / `done` / `toggle` / `text` (task state, exactly as Neovim's toggle: `@done(today)`, an `@id`), `set` (new text after the line's marker; `@id`/`@done` kept), `delete`, `insert` (after `lnum`; `kind` `task` / `note` / `text`), `move` (the line and the lines indented under it go before line `to`, `len+1` for the end, re-indented to fit; `expectTo` is that line's text). `expect` is the line as the page saw it: if the note changed since, nothing is written and the reply is 409 with the current note Task ops keep copies in step: the other lines with the task's `@id` in the calendar and the project notes get the same state (not `[>]` lines), and on a calendar line without a checkbox whose link points at a task they toggle that task (the reply then carries `task: {rel, lnum, line}`) |
| `POST /api/calendar/carry` | `-writable` only: `{date?}` (default today): copy the open tasks of the 14 days before to the date with the same `@id` and mark the old lines `[>]`, as Neovim's `:ZortexCarryForward`; `{moved, added}`. `GET /api/calendar` has `carry`, how many there are for today (the home page offers a **Carry** button) |
| `GET /api/note?rel=` | a rendered note: `{body, mod, src?}` (`src` with `-writable`) |
| `GET /api/events` | server-sent events for open pages: `notes` (`{rels}` added, changed or removed; seen on the next rescan, `-poll`), `xp` (a new summary), `pomodoro` (the clock changed), `clocks` (timers, alarms, stopwatch), `track` (time tracking). Pages redraw right away; behind nginx the stream needs `proxy_buffering off` (the server also sends `X-Accel-Buffering: no`) |
| `POST /api/inbox` | `-writable` only: `{text, kind: "task" \| "note"}` appended to `inbox.zortex` (created when missing) |
| `GET /api/clocks` | timers, alarms and the stopwatch: `{timers, alarms, stopwatch, now, ntfy}` |
| `POST /api/clocks/timers` | `{label, seconds}` starts a timer; `POST /api/clocks/timers/{id}/{pause,resume,restart,remove}` |
| `POST /api/clocks/alarms` | `{label, time: "HH:MM", repeat: "once" \| "daily"}`; `POST /api/clocks/alarms/{id}/{enable,disable,remove}` |
| `POST /api/clocks/stopwatch/{start,pause,toggle,lap,reset}` | the stopwatch |
| `GET /api/track` | time tracking: `{enabled, mode: calendar \| pinned \| off, task, counting, counted_ms, calendar?, error}` |
| `POST /api/track/pin` | `{rel, lnum, expect?}` work on this line; `POST /api/track/{follow,off,flush}`; `GET /api/track/tasks?q=` open tasks for the picker |
| `GET /api/digest?days=7&site=` | the coming days of the calendar: `{subject, text, html, days, count}`; links in `html` are absolute (`site`, else the request's host). E.g. `curl -s localhost:8090/api/digest \| jq -r .text \| mail -s Agenda me@example.com` from cron |
| `POST /api/pomodoro/settings` | `{work, short_break, long_break, long_break_after, auto_start_break, auto_start_work}` (minutes; partial updates are fine) |

`/notify`, `/pending` and `/test` require `X-API-Key` when `-api-key` is set.
Pomodoro POSTs must be JSON (or carry the key), so a cross-site form can't
drive the clock. Notifications more than 2 h overdue (server down) are
skipped rather than sent late; sent ones are kept a week.

**Pomodoro events** (ntfy tags): `pomodoro-work-start`,
`pomodoro-break-start`, `pomodoro-restart` (back to work after the long
break, or Restart cycle), `pomodoro-work-end` / `pomodoro-break-end` (the next
phase waits for you when auto-start is off), `pomodoro-stop`. Timers carry
`timer`, alarms `alarm`. A timer or alarm that came due while the server was
down is sent when it starts again if it is under 10 minutes late.

## Go packages

`app/` is a Go module (`github.com/t-wilkinson/zortex.nvim/app`):

- `syntax/`: the Zortex grammar, a port of `lua/zortex/core/syntax.lua`.
  `go test ./...` checks it against every fixture in `../tests/fixtures/ast`,
  which the Lua parser generates; both must agree byte for byte in their JSON.
- `notes/`: a notes folder: which files are notes, archived or not, parsed
  documents (cached by mtime and size) and section trees. Live mode reads
  the disk on every call (the CLI); after `Scan` it serves the last scan
  (the server), with a `Catalog` of names, tags and archived notes.
- `links/`: the link resolver (`Resolve`, `ResolveFirst`, `Parse`), checked
  against `../tests/fixtures/resolve.json`.
- `search/`: the structural search (`Build`, `Query`), checked against
  `../tests/fixtures/search.json`. Search history boosts are not ported.
- `web/`: the web app (handlers, note rendering, file browser, calendar,
  pomodoro and structure pages); templates and static files are embedded.
  `web_test.go` and `state_test.go` run it over the fixtures.
- `alerts/`: the notification store (a JSON file), the ntfy client and the
  sender loop.
- `tracker/`: time tracking (which task, what counts, when it's written),
  with the note writing left to a callback
- `clocks/`: timers, alarms and the stopwatch, persisted and announced through
  a callback, like the pomodoro
- `pomodoro/`: the pomodoro state machine, persisted and announced through a
  callback.
- `cmd/zortex`: `zortex parse [-pretty] FILE...` (AST as JSON),
  `zortex sections FILE...` (outline), `zortex resolve [-from REL] LINK...`,
  `zortex search [-mode article] PROMPT...`, `zortex serve`, `zortex version`.
  `-dir` defaults to `$ZORTEX_NOTES_DIR`, then the current folder.
- Nix: `nix build .#zortex`.
