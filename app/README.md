# Zortex app

The server side of Zortex: **`zortex serve`**, one Go binary with no
dependencies (this folder's Go module).

- **Notes**: rendered notes with working links and backlinks,
  structural search, a browser for every file in the folder (PDFs, images,
  media, text), tags, broken links, and the notes not yet linked from the
  Structure note.
- **Calendar** (home page): the days of `calendar.zortex` and the
  notifications Neovim sends from it (`POST /notify`). Due notifications
  are sent through **ntfy** by the server itself (no cron, no database),
  and kept for Neovim to show (`GET /api/alerts`).
- **Pomodoro**: a clock owned by the server, driven from the home page and
  from Neovim (`:ZortexPomodoro`, `<leader>zoo`). Phase changes go out
  through ntfy, each with its own tag so the desktop can play a different
  sound for starting work, starting a break and starting a new cycle
  ([`../contrib/ntfy`](../contrib/ntfy)).
- **Timer, alarm, stopwatch**: tabs next to the pomodoro on the home page.
  Timers and alarms (once or every day, at a time of day on the server's
  clock) ring through ntfy whether or not a page is open; every device sees
  the same ones.
- **Time tracking** (`-writable`): while a clock runs, its time goes to the
  task you're working on (the current calendar entry by default) and is
  added to the task's `@spent(...)`. See [Time tracking](../doc/Web.md#time-tracking).
- **Inbox** (`-writable`): the home page's box adds a task or a note to
  `inbox.zortex`, and keeps working offline in the installed app.

What the website does, page by page, and how it works with Neovim is in
[doc/Web.md](../doc/Web.md); running it on a server (sync, Docker, NixOS,
a login, ntfy, other calendars) in [doc/Server.md](../doc/Server.md). This
page has the flags, the NixOS options and the Go packages.

Notes are read-only unless `-writable` is set. The server's own state
(`notifications.json`, `pomodoro.json`, `clocks.json`, `track.json` and
`track_log.jsonl`, `search_history.json`, `web_completions.json`, the XP summary)
lives in `-data`. Without `-data` it serves the notes only. The server never
creates notes of its own except `inbox.zortex` (web edits),
`reviews.zortex` (the web reviews, when you write in one before Neovim made
it) and the calendar feeds' `z/feeds/<name>.zortex` (`-feeds`); finishing
a daily review on the web writes `.z/review_state.json`, as Neovim does; Neovim's
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

## `zortex serve`

```sh
go -C app run ./cmd/zortex serve -dir ~/notes            # http://127.0.0.1:8090/
nix run .#zortex -- serve -dir ~/notes -addr 0.0.0.0:8090
```

Flags (each also an environment variable): `-dir` (`ZORTEX_NOTES_DIR`),
`-addr` (`ZORTEX_ADDR`, default `127.0.0.1:8090`), `-base` (`ZORTEX_BASE`:
the URL prefix when a proxy serves it below `/`, e.g. `/notes`), `-title`
(`ZORTEX_TITLE`), `-poll` (`ZORTEX_POLL`, default `3s`), `-resources` (`ZORTEX_RESOURCES`: extensions tracked as resources; NixOS:
`web.resourceExtensions`).

Editing: `-writable` (`ZORTEX_WRITABLE=1`; NixOS `web.writable`) lets the
website edit notes ([Editing](../doc/Web.md#editing)); `-html-scripts`
(`ZORTEX_HTML_SCRIPTS=1`; NixOS `web.htmlScripts`) lets HTML files run
script in a sandbox ([Files](../doc/Web.md#files)). `-xp=false`
(`ZORTEX_XP=0`; NixOS `web.xp = false`) hides XP, the season and its
tiers, as `xp.enabled = false` does in Neovim.

**Login.** There is none by default: keep the server on `127.0.0.1` and
publish it through a proxy that has one (doc/Server.md). Without such a
proxy, `-auth-file FILE` (`ZORTEX_AUTH_FILE`; or `ZORTEX_AUTH=user:password`;
NixOS `web.authFile`) asks for a login (HTTP basic auth) on every page and
endpoint except `/healthz` (and `/calendar.ics` with its token); requests
with a valid `X-API-Key` (Neovim) pass.
The file has `user:password` lines. Use it over HTTPS. Listening on anything
but localhost without a login logs a warning.

State flags (with `-data`): `-data` (`ZORTEX_DATA_DIR`, or systemd's
`STATE_DIRECTORY`), `-ntfy-url` (`NTFY_SERVER_URL`), `-ntfy-topic`
(`NTFY_TOPIC`), `-ntfy-token` (`NTFY_AUTH_TOKEN`) or `-ntfy-token-file`,
`-api-key` (`ZORTEX_API_KEY`), `-send-interval` (default `20s`).

Calendar flags ([Other calendars](../doc/Server.md#6-other-calendars)):
`-feeds FILE` (`ZORTEX_FEEDS`): a JSON file of iCal links fetched into
`z/feeds/<name>.zortex`, which the calendar shows read-only (the server
writes those notes, so it needs write access to the folder);
`-share-token-file FILE` (`ZORTEX_SHARE_TOKEN_FILE`, or the token in
`ZORTEX_SHARE_TOKEN`): the token, 16 characters or more, that opens
`/calendar.ics?token=…` without the login.

**How it stays light.** The folder is read once at start and rescanned every
`-poll`. A rescan re-parses only files whose modification time or size
changed; when anything changed, the search index, backlinks, tags and broken
links are rebuilt in the background and swapped in. Notes keep their text,
section tree and a compact per-line summary; a page re-parses the one note it
shows. Measured on 2,000 generated notes (16 MB, 64,000 links): first index
about 2 s, rebuild about 2.5 s, search 30–60 ms, a note page 5 ms, about
120 MB resident with `GOMEMLIMIT=120MiB` (a typical folder is far smaller).
Bind to localhost and put a proxy with authentication in front, or give it
its own login with `-auth-file` ([Server.md](../doc/Server.md#3-put-it-behind-a-login)).

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
    # feeds.cozi.urlFile = "/run/secrets/cozi-ical-url";  # z/feeds/cozi.zortex
    # shareTokenFile = "/run/secrets/zortex-share-token"; # /calendar.ics?token=…
  };

  services.nginx.virtualHosts."zortex.home.lab" = {
    locations."/".proxyPass = "http://127.0.0.1:8090";
    basicAuthFile = "/run/secrets/zortex-htpasswd";
  };
}
```

Everything is one service on `web.port`. It runs as the `zortex` user with
read-only access to `notesDir` (writable with `web.writable` or `feeds`), a
writable `dataDir` (`/var/lib/zortex`) and the usual systemd hardening.
`feeds.<name>` takes `url` or `urlFile` (a credential), `enable`, `title`,
`notify`, `color`, `busy`, `every`, `daysBack` and `daysAhead`; an off
feed's note is removed.

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
  `../tests/fixtures/search.json`, and its history (`history.go`: the
  plugin's frecency boosts, kept in `-data/search_history.json`).
- `edit/`: single-line edits the way the plugin makes them (task open /
  done with `@done` and `@id`, text to task and back), task groups
  (`Groups`, `Cascade`), carrying tasks forward (`Carry`, and `ToNextDay`
  for the daily review's tomorrow) and the calendar auto-size,
  checked against `../tests/fixtures/{edits,groups,carry,autosize}.json`.
- `web/`: the web app (handlers, note rendering, file browser, calendar,
  pomodoro and structure pages; projects, objectives, areas (`areas.go`)
  and the daily and weekly reviews with their fixes (`review.go`,
  `reviewday.go`, `reviewapi.go`, `reviewsnote.go` for writing
  `reviews.zortex`); `/attributes` from `static/attributes.json`, which
  `tests/gen_docs.lua` writes); templates and static files are embedded.
  `web_test.go` and `state_test.go` run it over the fixtures.
- `alerts/`: the notification store (a JSON file), the ntfy client and the
  sender loop.
- `ical/`: iCalendar (RFC 5545) reading (events, `RRULE` repeats with
  `BYDAY`/`BYMONTHDAY`/`BYMONTH`/`COUNT`/`UNTIL`, `EXDATE`, `RDATE`,
  changed and cancelled occurrences, `TZID` zones) and expanding into
  occurrences; writing the `/calendar.ics` feed.
- `feeds/`: the calendar feeds (`-feeds`): fetch each link on its interval
  (conditional GET), write its window as `z/feeds/<name>.zortex` when it
  changed, remove the note of a feed turned off.
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
