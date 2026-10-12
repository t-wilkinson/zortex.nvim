# Zortex app

The server side of Zortex: **`zortex serve`**, one Go binary with no
dependencies (this folder's Go module).

- **Notes** (read-only): rendered notes with working links and backlinks,
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

Notes are only read; the server's own state (`notifications.json`,
`pomodoro.json`) lives in `-data`. Without `-data` it serves the notes only.

It replaces the old Flask notification server (SQLite, `send.sh`, cron) and
the Node app (now in [`../legacy`](../legacy)).

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
| `/` | search box, the **calendar** (days of `calendar.zortex`, a month grid, scheduled notifications), the **pomodoro** clock, **season and XP** (level and tier, progress to the next level, XP per day for two weeks, top areas, recent awards), the main notes (`-special`), recently changed notes, notes not yet in the structure, counts |
| `/structure` | notes that neither the Structure note (`@@Structure`) nor any `@Structure` note links to (archived notes left out) |
| `/n/<path>` | a rendered note: outline, every line anchored (`#L12`), links resolved with the plugin's rules (to the canonical target; `⁺` when there are more), broken links in red, file paths and markdown links to the file viewer, "Linked from" (backlinks) |
| `/search?q=` | structural search, the plugin's ranking: sections whose path matches the words in order, then lines with every word; results update as you type, `↑`/`↓` + Enter, `/` focuses search anywhere |
| `/link?to=&from=` | resolve a link: one target redirects, several are listed, failures say why |
| `/f/<path>` | file browser (sort by name (notes by article name) or modified time, either direction: `?sort=modified&order=desc`, kept in folder links; top level: the main notes unless "show all"; hidden folders and Syncthing artefacts never) and viewer: PDF, image, video, audio (with seeking), text, sandboxed HTML/SVG |
| `/raw/<path>` | the file as is: byte ranges, `?download=1`; HTML/SVG/XML with `Content-Security-Policy: sandbox`; nothing outside the folder, no hidden files |
| `/tags`, `/tag/<name>` | header tags and their notes |
| `/resources` | PDFs, books, images, media and documents, and which ones nothing links to (filter by unlinked/linked, type, folder); file pages show their own "Linked from", folder listings count links and unlinked files |
| `/broken` | links that don't resolve (notes and files) |
| `/api/search?q=`, `/api/resolve?to=&from=`, `/api/backlinks?rel=`, `/api/resources?show=unlinked&kind=&dir=`, `/api/structure` | JSON |
| `/healthz` (`/health`) | counts and last index time |

Flags (each also an environment variable): `-dir` (`ZORTEX_NOTES_DIR`),
`-addr` (`ZORTEX_ADDR`, default `127.0.0.1:8090`), `-base` (`ZORTEX_BASE`:
the URL prefix when a proxy serves it below `/`, e.g. `/notes`), `-title`
(`ZORTEX_TITLE`), `-poll` (`ZORTEX_POLL`, default `10s`), `-special`
(`ZORTEX_SPECIAL`, default `calendar,structure,projects,areas,okr`),
`-resources` (`ZORTEX_RESOURCES`: extensions tracked as resources; NixOS:
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
pages get clickable checkboxes and an Edit mode (tap a line: To-do · Done ·
Plain · Edit text · Add below · Delete); the home page checks off calendar
tasks and adds tasks and notes to `inbox.zortex`. Edits are single lines,
refused when the note changed since the page loaded, and written
atomically (through a `.syncthing.*.tmp` file Syncthing ignores). Task
edits match Neovim's exactly: `app/edit` is tested against
`tests/fixtures/edits.json`, which `tests/gen_edits.lua` writes from the
plugin's `tasks.edit_line`. XP isn't computed on the server: Neovim counts
completed tasks from their `@done` dates when it next runs (it reloads
changed notes on focus), and until then the home page shows how many web
completions are waiting.

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

The old `services.zortex.port`, `interval`, `notesUrl` and
`web.calendarUrl` options still evaluate (with a warning) but do nothing:
everything is one service on `web.port`. It runs as the `zortex` user with
read-only access to `notesDir`, a writable `dataDir` (`/var/lib/zortex`) and
the usual systemd hardening.

## Notification and pomodoro API

| endpoint | |
|---|---|
| `POST /notify` | `{user_id, operation: "sync", notifications: [...]}` replaces the user's pending notifications (unchanged ones keep their identity; an identical manifest is a no-op: `{unchanged: true}`); `operation: "notify"` adds one; `"clear"` removes the pending ones |
| `GET /pending?user_id=` | pending notifications |
| `POST /test` | `{title?, message?}`: publish through ntfy now and report |
| `GET /api/calendar?from=&to=` | `days` (entries of `calendar.zortex` with time, text, rendered HTML, task state, whether a notification is scheduled), `notifications`, `count`, `next_event`; plus the old server's `events` / `text_view` |
| `GET /api/summary` | for homelab dashboards: pending count, upcoming notifications as text/HTML, the pomodoro |
| `GET /api/pomodoro` | phase, running, remaining, ends_at, session, completed, today, settings, `next_alarm`, `ntfy` |
| `POST /api/pomodoro/{start,pause,resume,toggle,skip,stop,restart}` | drive the clock |
| `GET /api/xp` | the XP summary Neovim published (season, daily XP, areas, recent awards), or `{"available": false}` |
| `POST /api/xp` | Neovim publishes it after every XP change (`X-API-Key` when set); it also writes `.z/xp_summary.json` into the notes folder, and the newer of the two is shown |
| `POST /api/edit` | `-writable` only: `{rel, lnum, expect, op, text?, kind?}` with `op` `open` / `done` / `toggle` / `text` (task state, exactly as Neovim's toggle: `@done(today)`, an `@id`), `set` (new text after the line's marker; `@id`/`@done` kept), `delete`, `insert` (after `lnum`; `kind` `task` / `note` / `text`). `expect` is the line as the page saw it: if the note changed since, nothing is written and the reply is 409 with the current note |
| `POST /api/inbox` | `-writable` only: `{text, kind: "task" \| "note"}` appended to `inbox.zortex` (created when missing) |
| `POST /api/pomodoro/settings` | `{work, short_break, long_break, long_break_after, auto_start_break, auto_start_work}` (minutes; partial updates are fine) |

`/notify`, `/pending` and `/test` require `X-API-Key` when `-api-key` is set.
Pomodoro POSTs must be JSON (or carry the key), so a cross-site form can't
drive the clock. Notifications more than 2 h overdue (server down) are
skipped rather than sent late; sent ones are kept a week.

**Pomodoro events** (ntfy tags): `pomodoro-work-start`,
`pomodoro-break-start`, `pomodoro-restart` (back to work after the long
break, or Restart cycle), `pomodoro-work-end` / `pomodoro-break-end` (the next
phase waits for you when auto-start is off), `pomodoro-stop`.

**Migrating from the Flask server**: point the plugin's `server.api_endpoint`
at `zortex serve` (port 8090 by default, plus `-base` if set) and save the
calendar once (or `:ZortexNotificationsSync force`); the old
`notifications.db` isn't read. The Flask `/api/notes/*` endpoints are gone:
the web app's pages and `/api/search`, `/api/resolve`, `/raw/…` cover them.

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
- `pomodoro/`: the pomodoro state machine, persisted and announced through a
  callback.
- `cmd/zortex`: `zortex parse [-pretty] FILE...` (AST as JSON),
  `zortex sections FILE...` (outline), `zortex resolve [-from REL] LINK...`,
  `zortex search [-mode article] PROMPT...`, `zortex serve`, `zortex version`.
  `-dir` defaults to `$ZORTEX_NOTES_DIR`, then the current folder.
- Nix: `nix build .#zortex`.
