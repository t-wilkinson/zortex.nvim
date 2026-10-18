# Running the server

`zortex serve` is optional. It is one Go binary with no dependencies that
reads your notes folder and gives you:

- the notes on the web: rendered, with working links, backlinks, search, a
  file browser, tags and broken links;
- a home page with today's calendar, the pomodoro (shared with Neovim),
  timers, alarms, a stopwatch, time tracking and your season's XP;
- calendar notifications and alarms on your phone through
  [ntfy](https://ntfy.sh);
- other calendars in yours (a Cozi or Google calendar's iCal link), and
  your calendar's `@share` lines in theirs ([section 6](#6-other-calendars));
- with `-writable`, light editing: check off tasks, edit, add, move and
  delete lines, add to the inbox.

This guide gets it running. What the website does, page by page, and how
it works with Neovim is in [Web.md](Web.md); every flag is in
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
  reads `.z/xp_summary.json` and `.z/time_spent.json` from there (Neovim
  writes them as they change), so don't leave `.z` out of the sync
  (`.stignore`). Leave it out of a git backup instead
  ([Backups](../README.md#backups)): it is state, not notes.
- **Calendar feeds write into the folder.** With `-feeds`
  ([section 6](#6-other-calendars)) the server writes `z/feeds/<name>.zortex`
  itself, so it needs write access to the notes even without `-writable`,
  and the sync carries those notes to Neovim.
- **Conflicts.** When both sides change one note before a sync, the tool
  keeps both (Syncthing writes `note.sync-conflict-….zortex`, Dropbox and
  Nextcloud `note (… conflicted copy …).zortex`). Zortex leaves these copies
  out of the notes, so a copy of `projects.zortex` doesn't double every
  project, and the file browser hides them; `:checkhealth zortex` lists
  them. Merge each into its note by hand and delete it.
- **Keep history.** A sync tool copies a mistake to every device; keep
  the folder in git on this machine (the README's
  [Backups](../README.md#backups) has a daily commit).
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
    # other calendars in yours, and yours in theirs (section 6)
    feeds.cozi = { title = "Family"; urlFile = "/run/secrets/cozi-ical-url"; };
    shareTokenFile = "/run/secrets/zortex-share-token";
  };
}
```

The service is sandboxed: read-only access to the notes (unless writable,
or with calendar feeds, which write `z/feeds/`), its own state directory,
nothing else.

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

## 6. Other calendars

### Their events in your calendar: `-feeds`

Most calendar apps give each calendar a private iCal link (an address
ending in `.ics`, or `webcal://`): Cozi under *Settings → Calendar → Share
calendar* ("Connected calendars", one link per family member, or one for
everyone), Google under a calendar's *Settings → Integrate calendar →
Secret address in iCal format*, Apple's iCloud under *Public calendar*. The
server fetches each link you list every 15 minutes and writes its events
into a note, `z/feeds/<name>.zortex`, which the calendar view, the planner,
the agenda and the web app's home page show among your own, read-only and
labelled with the feed's name (`· cozi`):

```json
{
  "feeds": [
    { "name": "cozi", "title": "Family", "url_file": "/run/secrets/cozi-ical-url", "notify": true, "color": "#2a9d8f" },
    { "name": "school", "url": "https://example.edu/calendar.ics", "notify": true, "busy": false },
    { "name": "old-job", "url": "https://...", "enabled": false }
  ]
}
```

```sh
zortex serve ... -feeds ~/.config/zortex/feeds.json    # or ZORTEX_FEEDS
```

| field | default | what |
|---|---|---|
| `name` | (required) | the note's name, `z/feeds/<name>.zortex`, and the label; letters, digits, `-` and `_` |
| `title` | the name | the note's `@@` title |
| `url` / `url_file` | (one of them) | the link (`https://` or `webcal://`); a private link is a secret, so prefer a file holding it |
| `enabled` | `true` | `false` stops fetching it and removes its note: its events leave every calendar view |
| `notify` | `false` | `true`: its timed events notify as yours do; off, each line gets `@n(no)` |
| `color` | `#e8833a` | with `notify`, the dot its days get on the web app's month grid, beside the one for your `@event`s, and on its label in the day's list: `#rrggbb`, a CSS color name, `rgb()` or `hsl()` |
| `busy` | `true` | its events take time in the planner's capacity line; `false` adds `@free` to each line |
| `every` | `15m` | how often to fetch it (5m at least); unchanged feeds aren't downloaded again (`ETag`) |
| `days_back`, `days_ahead` | 7, 60 | the days the note covers |

Repeating events, exceptions, cancelled occurrences and time zones are
expanded into one line per day, at your server's time (`TZ`), in the
calendar's syntax (`16:00 - 17:00 Soccer · Field 3 @n(no)`; an all-day event
is `- Camping` on each of its days). The note is rewritten only when the
feed changed, so Syncthing stays quiet, and edits to it are replaced: change
what the feed says in the calendar it comes from. If a fetch fails, the
last note stays.

To hide a feed in Neovim only, `features.calendar_feeds = { cozi = false }`
(`false` hides them all); `enabled: false` hides it everywhere. Notifying
feeds are notified through Neovim, like the rest of the calendar (step 5).

### Your events in their calendar: `/calendar.ics`

Tag a calendar line `@share` and it is in `/calendar.ics`, an iCal feed of
your calendar's shared lines (30 days back to 180 ahead) that Cozi, Google
or Apple can subscribe to:

```
**2026-10-21:**
09:00 - 12:00 Deep work on [P/#1.4 - zortex]
16:00 [ ] Pick up the kids @share
- Mum's birthday @share
```

Only `@share` lines leave, as their text (a link becomes its name); a timed
line without an end lasts 30 minutes, a line without a time is an all-day
event, and each event links back to its line on the web app.

A calendar app can't log in, so give the feed a token of its own: a file
holding 16 characters or more (`openssl rand -hex 16`), passed with
`-share-token-file` (`ZORTEX_SHARE_TOKEN_FILE`, or the token itself in
`ZORTEX_SHARE_TOKEN`; `shareTokenFile` on NixOS). Then subscribe to

```
https://notes.example.com/calendar.ics?token=<token>
```

(Cozi: *Settings → Calendar → Connected calendars → Add*, Google: *Other
calendars → From URL*.) The token opens that one address, nothing else.
Without `-auth-file`, the server answers `/calendar.ics` only to the token;
with it, either the token or the login. Calendar apps refresh subscribed
feeds on their own schedule, from every few minutes to a day.

Behind a proxy with its own login, let `/calendar.ics` through to the app
(the token protects it). Authelia, for example:

```yaml
access_control:
  rules:
    - domain: notes.example.com
      resources: ['^/calendar\.ics([?].*)?$']   # '^/notes/calendar...' with -base /notes
      policy: bypass
    - domain: notes.example.com
      policy: one_factor
```

Caddy with `basic_auth`: a `handle /calendar.ics` block without it, as for
the app icons ([Installing it as an app](Web.md#installing-it-as-an-app)).

## Installing it as an app

The website installs as an app on a phone or desktop (over HTTPS), reads
recent pages offline and keeps inbox captures until the server is back;
behind a login, let `/manifest.webmanifest` and `/static/icons/` through.
See [Installing it as an app](Web.md#installing-it-as-an-app).

## Checking it works

- `http://127.0.0.1:8090/healthz`: note and link counts, last index time.
- `zortex version`
- `curl -X POST -H 'Content-Type: application/json' -d '{"title":"Hi","message":"Test"}' http://127.0.0.1:8090/test`
  sends a test notification through ntfy.
