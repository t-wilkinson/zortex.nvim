# Zortex app

The server side of Zortex, in two independent parts:

- **`zortex serve`** (Go, this folder's Go module): the notes web app.
  Rendered notes with working links and backlinks, structural search, a
  browser for every file in the folder (PDFs, images, media, text), tags
  and broken links. Read-only, one static binary, no dependencies.
- **The notification server** (Flask + SQLite): the notification API (the
  plugin pushes calendar notifications; a systemd timer sends them to ntfy)
  and a dashboard with a Calendar tab and a simpler Notes tab.

It replaces the old Node app, now in [`../legacy`](../legacy).

## Web app: `zortex serve`

```sh
go -C app run ./cmd/zortex serve -dir ~/notes            # http://127.0.0.1:8090/
nix run .#zortex -- serve -dir ~/notes -addr 0.0.0.0:8090
```

| page | what |
|---|---|
| `/` | search box, the main notes (`-special`), recently changed notes, counts |
| `/n/<path>` | a rendered note: outline, every line anchored (`#L12`), links resolved with the plugin's rules (to the canonical target; `⁺` when there are more), broken links in red, file paths and markdown links to the file viewer, "Linked from" (backlinks) |
| `/search?q=` | structural search, the plugin's ranking: sections whose path matches the words in order, then lines with every word; results update as you type, `↑`/`↓` + Enter, `/` focuses search anywhere |
| `/link?to=&from=` | resolve a link: one target redirects, several are listed, failures say why |
| `/f/<path>` | file browser (top level: the main notes unless "show all"; hidden folders and Syncthing artefacts never) and viewer: PDF, image, video, audio (with seeking), text, sandboxed HTML/SVG |
| `/raw/<path>` | the file as is: byte ranges, `?download=1`; HTML/SVG/XML with `Content-Security-Policy: sandbox`; nothing outside the folder, no hidden files |
| `/tags`, `/tag/<name>` | header tags and their notes |
| `/broken` | links that don't resolve |
| `/api/search?q=`, `/api/resolve?to=&from=`, `/api/backlinks?rel=` | JSON |
| `/healthz` | counts and last index time |

Flags (each also an environment variable): `-dir` (`ZORTEX_NOTES_DIR`),
`-addr` (`ZORTEX_ADDR`, default `127.0.0.1:8090`), `-base` (`ZORTEX_BASE`:
the URL prefix when a proxy serves it below `/`, e.g. `/notes`), `-title`
(`ZORTEX_TITLE`), `-poll` (`ZORTEX_POLL`, default `10s`), `-special`
(`ZORTEX_SPECIAL`, default `calendar,structure,projects,areas,okr`).

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

### NixOS

```nix
{
  imports = [ zortex.nixosModules.default ];
  services.zortex = {
    notesDir = "/var/lib/syncthing/zortex";
    notesGroup = "syncthing";        # read access to the synced folder
    web = {
      enable = true;                 # zortex-web.service on 127.0.0.1:8090
      # basePath = "/notes";         # when proxied below "/"
      # pollInterval = "30s";
      # memoryLimit = "96MiB";       # GOMEMLIMIT (default 128MiB)
    };
    enable = true;                   # the notification server (optional)
  };

  services.nginx.virtualHosts."notes.home.lab" = {
    locations."/".proxyPass = "http://127.0.0.1:8090";
    basicAuthFile = "/run/secrets/notes-htpasswd";
  };
}
```

`zortex-web` runs as the `zortex` user with read-only access to `notesDir`
and the usual systemd hardening (read-only system and home, no
capabilities, no new privileges, a system call filter).

## Notes tab (notification server)

Set `NOTES_DIR` to the synced notes folder (Docker: mount it read-only at
`/notes`, see `docker-compose.yml`; NixOS: `services.zortex.notesDir`, plus
`notesGroup = "syncthing"` for read access).

- **Search** matches every word against note names, aliases, tags and paths
  (exact, prefix, substring, like the plugin; archived notes last), then lists
  lines containing every word. Other files match by name, folder and
  extension (`pdf papers`).
- **Other files** (PDFs, images, video, audio, text, …) are listed next to
  the notes and open in the viewer: PDFs in the browser's PDF viewer, images,
  `<video>`/`<audio>` (with seeking), text files up to 2 MB inline; anything
  else gets open/download links. Untick "other files" to see notes only.
- **Browse** the folder tree; open a note to read it with basic highlighting;
  links like `/#notes/z/rust.zortex:12` open a note at a line.
- **Hidden by default:** top-level files other than the special notes (`NOTES_SPECIAL`, default `calendar,structure,projects,areas,okr`; tick
  "all top-level notes" to see them), hidden folders (`.z`, `.stversions`,
  …) and Syncthing temp/conflict files. Nothing is ever written to the folder.
- JSON: `GET /api/notes/tree?all=0&files=1`,
  `/api/notes/search?q=…&all=0&files=1&limit=50`,
  `/api/notes/file?path=z/rust.zortex` (a note's lines, or a file's metadata).
- Raw files: `GET /api/notes/raw?path=z/papers/x.pdf` (`&download=1` to
  save). Served with their MIME type and byte ranges; only files inside the
  folder (no `..`, no symlinks out, no hidden files); HTML/SVG/XML are served
  with `Content-Security-Policy: sandbox` so they can't run script on the
  dashboard's origin.
- Tests: `python3 -m unittest app/test_notes.py`.

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
- `web/`: the web app (handlers, note rendering, file browser); templates
  and static files are embedded. `web_test.go` runs it over the fixtures.
- `cmd/zortex`: `zortex parse [-pretty] FILE...` (AST as JSON),
  `zortex sections FILE...` (outline), `zortex resolve [-from REL] LINK...`,
  `zortex search [-mode article] PROMPT...`, `zortex serve`, `zortex version`.
  `-dir` defaults to `$ZORTEX_NOTES_DIR`, then the current folder.
- Nix: `nix build .#zortex`.

## Notifications

- Flask API server to receive notification manifests
- SQLite database for persistent notification storage
- Cron job that checks every minute for pending notifications
- Automatic cleanup of old notifications
- Deduplication to prevent duplicate notifications
- Integration with ntfy for push notifications

## Setup

### 1. Directory Structure

Create the following directory structure:

```
zortex-notifications/
├── Dockerfile
├── server.py
├── send.sh
├── init_db.py
├── crontab
├── requirements.txt
├── .env
└── docker-compose.yml
```

### 2. Configuration

Copy `.env.example` to `.env` and configure:

```bash
# For public ntfy.sh
NTFY_SERVER_URL=http://ntfy.sh
NTFY_TOPIC=your-unique-topic-name

# For self-hosted ntfy
NTFY_SERVER_URL=http://your-ntfy-server.com
NTFY_TOPIC=private-topic
NTFY_AUTH_TOKEN=your-auth-token
```

### 3. Build and Run

Using Docker Compose:

```bash
docker-compose up -d
```

Or standalone Docker:

```bash
# Build
docker build -t zortex-notifications .

# Run
docker run -d \
  --name zortex-notifications \
  -p 5001:5000 \
  -v zortex_data:/app/data \
  -e NTFY_SERVER_URL=http://ntfy.sh \
  -e NTFY_TOPIC=your-topic \
  zortex-notifications
```

### 4. Update Lua Configuration

In your Zortex configuration, update the homelab provider settings:

```lua
notifications = {
  providers = {
    homelab = {
      enabled = true,
      api_endpoint = "http://localhost:5001",  -- or your server URL
      user_id = "your-user-id",
      api_key = "optional-api-key"  -- if you add authentication
    }
  }
}
```

## API Endpoints

### Health Check

```
GET /health
```

### Test Complete Flow (NEW)

```
GET/POST /test
```

Tests the complete notification flow end-to-end. Adds a notification to the database, triggers send.sh, and verifies it was sent to ntfy.

**GET Method (easy browser/curl testing):**

```bash
curl "http://localhost:5001/test?user_id=test&title=Test&message=Hello"
```

**POST Method (with delay):**

```bash
curl -X POST http://localhost:5001/test \
  -H "Content-Type: application/json" \
  -d '{
    "user_id": "test",
    "title": "Test Notification",
    "message": "This is a test",
    "delay": 5
  }'
```

Response includes complete diagnostics:

```json
{
  "success": true,
  "test_results": {
    "notification_id": 123,
    "database_insert": "success",
    "run_script_executed": true,
    "notification_sent": true,
    "overall_status": "SUCCESS"
  }
}
```

### Send/Sync Notifications

```
POST /notify
Content-Type: application/json

# Single notification
{
  "user_id": "user123",
  "operation": "notify",
  "notification": {
    "title": "Meeting Reminder",
    "message": "Team standup in 15 minutes",
    "scheduled_time": 1699123456,
    "priority": "high",
    "tags": ["meeting", "work"]
  }
}

# Bulk sync (replaces all pending)
{
  "user_id": "user123",
  "operation": "sync",
  "notifications": [
    {
      "title": "Event 1",
      "message": "Description",
      "scheduled_time": 1699123456,
      "priority": "default",
      "tags": ["calendar"]
    }
  ]
}
```

### View Pending Notifications

```
GET /pending?user_id=user123
```

## How It Works

1. **Receiving Notifications**: The Lua calendar system sends notification manifests to the Flask server
2. **Storage**: Notifications are stored in SQLite with scheduled times
3. **Scheduling**: A cron job runs every minute to check for pending notifications
4. **Sending**: Due notifications are sent to your ntfy server/topic
5. **Cleanup**: Old sent notifications are automatically removed after 7 days

## Testing

Test the notification system:

```bash
# Test single notification (immediate)
curl -X POST http://localhost:5001/notify \
  -H "Content-Type: application/json" \
  -d '{
    "user_id": "test",
    "operation": "notify",
    "notification": {
      "title": "Test Notification",
      "message": "This is a test",
      "scheduled_time": '$(date +%s)',
      "priority": "high"
    }
  }'

# Check pending notifications
curl http://localhost:5001/pending?user_id=test
```

## Monitoring

View logs:

```bash
# Server logs
docker logs zortex-notifications

# Notification send logs
docker exec zortex-notifications cat /var/log/zortex-notifications.log

# Cron logs
docker exec zortex-notifications cat /var/log/cron.log
```

## Security Notes

- The server binds to 127.0.0.1:5001 by default (localhost only)
- For remote access, use a reverse proxy with authentication
- Consider adding API key authentication if exposing to network
- Use HTTPS when deployed on public networks

## Integration with Reverse Proxy

### Traefik

Labels are included in docker-compose.yml for automatic Traefik configuration.

### Nginx Proxy Manager

1. Add a new proxy host
2. Domain: `zortex.yourdomain.com`
3. Forward to: `zortex-notifications:5000`
4. Enable SSL and force SSL

### Caddy

```
zortex.yourdomain.com {
    reverse_proxy zortex-notifications:5000
}
```

## Troubleshooting

1. **Notifications not sending**: Check ntfy configuration and server accessibility
2. **Database errors**: Ensure `/app/data` volume is writable
3. **Cron not running**: Check cron logs and ensure crontab has proper line endings
4. **Connection refused**: Verify the container is running and ports are mapped correctly
