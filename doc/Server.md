# Running the server

`zortex serve` is optional. It is one Go binary with no dependencies that
reads your notes folder and gives you:

- the notes on the web: rendered, with working links, backlinks, search, a
  file browser, tags and broken links;
- a home page with today's calendar, the pomodoro (shared with Neovim),
  timers, alarms, a stopwatch, time tracking and your season's XP;
- calendar notifications and alarms on your phone through
  [ntfy](https://ntfy.sh);
- with `-writable`, light editing: check off tasks, edit, add, move and
  delete lines, add to the inbox.

This guide gets it running. Every flag, page and endpoint is in
[app/README.md](../app/README.md).

## 1. Get the notes to the server

The server reads a folder of notes; it doesn't sync them. Run it where the
notes already are (your laptop), or keep a copy on the server in step with
the one Neovim edits. With `-writable` the web app edits notes too (tasks,
the inbox, carried tasks), so the sync has to run both ways.

| Tool | Both ways | Good for |
| --- | --- | --- |
| [Syncthing](https://syncthing.net) | yes, continuous | the usual choice (what the author uses): phone, laptop and server stay in step within seconds |
| Nextcloud, Dropbox, iCloud Drive and similar | yes | a sync client you already run; point `-dir` at its folder on the server |
| [Unison](https://github.com/bcpierce00/unison) | yes, on demand or `-repeat watch` | two machines over SSH, no daemon on the server |
| git | yes, by hand (commit, pull, push) | history and review; a pull on the server (cron or a hook) updates it, edits from the web need a commit and push back |
| rsync | one way | a read-only web app (no `-writable`): `rsync -a --delete ~/zortex/ server:zortex/` after you edit |

Whatever you use:

- **Sync `.z/` too.** Neovim's state lives in `notes/.z/`. The web app
  reads `.z/xp_summary.json` from there (Neovim writes it after every XP
  change), so don't leave `.z` out (`.stignore`, `.gitignore`) unless you
  also point the plugin at the server (step 5).
- **Conflicts.** When both sides change one note before a sync, the tool
  keeps both (Syncthing writes `note.sync-conflict-….zortex`, Dropbox and
  Nextcloud `note (… conflicted copy …).zortex`). Zortex leaves these copies
  out of the notes, so a copy of `projects.zortex` doesn't double every
  project, and the file browser hides them; `:checkhealth zortex` lists
  them. Merge each into its note by hand and delete it.
- **Syncthing: lower the delay.** Syncthing waits 10 s before syncing a
  change by default; set the folder's *Advanced → fsWatcherDelayS* to 1 or
  2 so the web pages follow Neovim closely. The server itself rescans every
  3 s (`-poll`).

## 2. Run it

Binaries for Linux and macOS are on the
[releases page](https://github.com/t-wilkinson/zortex.nvim/releases), or
build it with Go 1.22+:

```sh
go -C app build -o ~/.local/bin/zortex ./cmd/zortex
zortex serve -dir ~/zortex -data ~/.local/state/zortex     # http://127.0.0.1:8090/
```

`-dir` is the notes folder. `-data` is the server's own state; without it you
get the notes only (no calendar notifications, pomodoro, clocks or time
tracking). What lives in `-data`:

| file | what |
|---|---|
| `notifications.json` | notifications Neovim scheduled from the calendar |
| `pomodoro.json` | the pomodoro clock |
| `clocks.json` | timers, alarms, the stopwatch |
| `track.json`, `track_log.jsonl` | time tracking: the current task, and every time written to a task |
| `xp_summary.json` | the XP summary when Neovim posts it (step 5) |
| `web_completions.json` | tasks completed on the web, until Neovim counts their XP |
| `search_history.json` | what you opened from the search page, which ranks it higher next time |

Add `-writable` to edit from the browser (the notes folder must be writable
by the server). Edits are line-level and refused when the note changed since
the page loaded; files are replaced atomically, so Syncthing never sees half
a file.

Add `-html-scripts` to let HTML files in the notes run JavaScript in the file
viewer. They run sandboxed, in an opaque origin: no access to the site's
pages or files, and their POSTs are refused. Use it only for HTML you trust.

### Docker

```sh
docker run -d --name zortex -p 127.0.0.1:8090:8090 \
  -v ~/zortex:/notes -v zortex-data:/data \
  -e TZ=America/New_York -e NTFY_TOPIC=my-zortex-topic \
  ghcr.io/t-wilkinson/zortex:latest
```

Mount the notes read-only (`/notes:ro`) unless you add `-e ZORTEX_WRITABLE=1`.
[`app/docker-compose.yml`](../app/docker-compose.yml) does the same with a
`.env` file; it refuses to start without `NTFY_TOPIC` (a private,
hard-to-guess topic). Set `TZ`: the calendar and alarms use the server's
time zone (UTC when unset). On NixOS, `timezone` follows `time.timeZone`.

### NixOS

```nix
{
  inputs.zortex.url = "github:t-wilkinson/zortex.nvim";
  # ...
  imports = [ inputs.zortex.nixosModules.default ];
  services.zortex = {
    enable = true;
    notesDir = "/var/lib/syncthing/zortex";
    notesGroup = "syncthing";        # read (and, with web.writable, write) access
    timezone = "America/New_York";
    ntfy.topic = "my-zortex-topic";
    ntfy.authTokenFile = "/run/secrets/ntfy-token";
    apiKeyFile = "/run/secrets/zortex-api-key";   # ZORTEX_API_KEY=...
    web.writable = true;
  };
}
```

The service is sandboxed: read-only access to the notes (unless writable),
its own state directory, nothing else.

## 3. Put it behind a login

The server has **no login of its own**: anyone who can reach the port can
read every note. Keep it on `127.0.0.1` (the default) and publish it through
a reverse proxy with authentication, or over a private network such as
Tailscale.

Caddy, with a password:

```
notes.example.com {
  basic_auth {
    me $2a$14$...   # caddy hash-password
  }
  reverse_proxy 127.0.0.1:8090
}
```

nginx: the pages get live updates over server-sent events, which must not
be buffered:

```nginx
location / {
  auth_basic "zortex";
  auth_basic_user_file /etc/nginx/zortex.htpasswd;
  proxy_pass http://127.0.0.1:8090;
  proxy_buffering off;          # /api/events
  proxy_read_timeout 1h;
}
```

To serve it below a path (`https://example.com/notes/`), pass `-base /notes`
and let the proxy forward the prefix.

No proxy with a login? `-auth-file` (a file of `user:password` lines; or
`ZORTEX_AUTH=user:password` in Docker; `web.authFile` on NixOS) makes the
server ask for one itself. It is HTTP basic auth, so serve it over HTTPS
(Caddy without `basic_auth`, Tailscale): the password goes with every
request. Neovim's requests pass with the API key.

## 4. Notifications with ntfy

[ntfy](https://ntfy.sh) delivers calendar notifications, pomodoro phase
changes, timers and alarms. Pick a hard-to-guess topic (anyone who knows it
can read it) or run your own ntfy server with access tokens:

```sh
zortex serve ... -ntfy-url https://ntfy.sh -ntfy-topic my-zortex-topic
# -ntfy-token-file /run/secrets/ntfy-token for a protected topic
```

Subscribe in the ntfy phone app. On the desktop,
[`contrib/ntfy`](../contrib/ntfy) has a `client.yml` and `notify.sh` for
`ntfy subscribe`, which plays a different sound for starting work, starting
a break, a timer and an alarm (`ZORTEX_SOUND_*` pick the files and
`ZORTEX_SOUND_PLAYER` the player; see the script's header).

## 5. Connect Neovim

```lua
require("zortex").setup({
  notes_dir = "~/zortex",
  server = {
    enabled = true,
    api_endpoint = "https://notes.example.com", -- or http://127.0.0.1:8090
    api_key = os.getenv("ZORTEX_API_KEY"),        -- the server's -api-key, if set
  },
  notifications = {
    providers = { ntfy = { enabled = true, topic = "my-zortex-topic" } },
  },
})
```

With `server.enabled`:

- saving `calendar.zortex` sends its notifications to the server, which
  delivers them through ntfy when they're due (unchanged calendars aren't
  re-sent; `:ZortexNotificationsSync force` resends);
- `<leader>zoo` and the `:ZortexPomodoro…` commands drive the server's
  pomodoro, the same one as the home page;
- the XP summary is posted to the server as well as written to `.z/`.

`:ZortexPresent` (`<leader>zS`, with or without `server.enabled`) opens the
note as slides at the slide under the cursor; set `server.web_url` when the
browser reaches the web app at another address than `api_endpoint`.

Set `-api-key` (or `ZORTEX_API_KEY`) on the server so only Neovim can post
to `/notify`, `/pending` and `/api/xp`; the browser pages don't need it.

## Installing it as an app

The web app is installable (a PWA): on a phone, open it in the browser and
choose **Add to Home Screen** (Safari) or **Install app** (Chrome); on the
desktop, the install button in Chrome's or Edge's address bar. It opens in
its own window, without the browser's bars, at the home page; long-pressing
the icon offers Search and Projects (and Add to inbox with `-writable`). Browsers allow this over HTTPS only
(and on `localhost`), so serve it as in [section 3](#3-put-it-behind-a-login).

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

## Checking it works

- `http://127.0.0.1:8090/healthz`: note and link counts, last index time.
- `zortex version`
- `curl -X POST -H 'Content-Type: application/json' -d '{"title":"Hi","message":"Test"}' http://127.0.0.1:8090/test`
  sends a test notification through ntfy.
