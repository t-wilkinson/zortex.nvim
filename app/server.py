#!/usr/bin/env python3
# app/server.py
import os
import sqlite3
import json
import logging
from datetime import datetime, timezone, timedelta
from itertools import groupby
from flask import Flask, request, jsonify, render_template_string, send_file
from contextlib import contextmanager
from html import escape as html_escape
from zoneinfo import ZoneInfo

from notes import NotesIndex, classify, guess_mime, DEFAULT_SPECIAL

app = Flask(__name__)

# Configuration
state_dir = os.environ.get("STATE_DIRECTORY")
if state_dir:
    default_db_path = os.path.join(state_dir, "notifications.db")
else:
    default_db_path = os.path.join(os.getcwd(), "data", "notifications.db")
DATABASE_PATH = os.environ.get("DATABASE_PATH", default_db_path)
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO")
FLASK_PORT = int(os.environ.get("FLASK_PORT", 5000))

TZ_NAME = os.environ.get("TZ", "America/New_York")
try:
    LOCAL_TZ = ZoneInfo(TZ_NAME)
except Exception:
    LOCAL_TZ = timezone.utc

# The notes web app (zortex serve): its URL as the browser sees it, e.g.
# "/notes" on the same host or "https://notes.home.lab". It provides the top
# bar's Files, Tags and Broken tabs and the search box; empty leaves them out.
NOTES_URL = os.environ.get("NOTES_URL", "")
SITE_TITLE = os.environ.get("ZORTEX_TITLE", "Zortex")
# The shared theme lives with the notes app (app/web/static)
STATIC_DIR = os.environ.get(
    "ZORTEX_STATIC_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), "web", "static")
)

# Notes folder (optional): the synced zortex directory, read-only
NOTES_DIR = os.environ.get("NOTES_DIR")
NOTES_SPECIAL = [x for x in os.environ.get("NOTES_SPECIAL", ",".join(DEFAULT_SPECIAL)).split(",") if x.strip()]
NOTES = (
    NotesIndex(NOTES_DIR, os.environ.get("NOTES_EXTENSION", ".zortex"), NOTES_SPECIAL)
    if NOTES_DIR and os.path.isdir(os.path.expanduser(NOTES_DIR))
    else None
)

# Setup logging
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL.upper()),
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)


@contextmanager
def get_db():
    """Context manager for database connections"""
    # Ensure directory exists before connecting
    os.makedirs(os.path.dirname(DATABASE_PATH), exist_ok=True)

    conn = sqlite3.connect(DATABASE_PATH)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
        conn.commit()
    except Exception as e:
        conn.rollback()
        raise e
    finally:
        conn.close()


def init_database():
    """Initialize database if it doesn't exist"""
    try:
        os.makedirs(os.path.dirname(DATABASE_PATH), exist_ok=True)

        with get_db() as conn:
            cursor = conn.cursor()
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS notifications (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    user_id TEXT NOT NULL,
                    entry_id TEXT,
                    title TEXT NOT NULL,
                    message TEXT NOT NULL,
                    scheduled_time INTEGER NOT NULL,
                    priority TEXT DEFAULT 'default',
                    tags TEXT,
                    created_at INTEGER NOT NULL,
                    sent_at INTEGER,
                    deduplication_key TEXT,
                    UNIQUE(user_id, deduplication_key)
                )
            """)
            cursor.execute(
                "CREATE INDEX IF NOT EXISTS idx_scheduled ON notifications(scheduled_time)"
            )
            cursor.execute(
                "CREATE INDEX IF NOT EXISTS idx_user ON notifications(user_id)"
            )
            cursor.execute(
                "CREATE INDEX IF NOT EXISTS idx_sent ON notifications(sent_at)"
            )
            logger.info(f"Database initialized at {DATABASE_PATH}")
    except Exception as e:
        logger.error(f"Failed to initialize database: {e}")
        raise


# ==============================================================================
#  Helpers & Views for Homepage
# ==============================================================================


def get_zortex_calendar_view():
    """Generates the text-based calendar view, stats, and raw event data"""
    now = datetime.now(LOCAL_TZ)
    now_ts = now.timestamp()

    # Fetch events starting from 30 days ago to populate past calendar days
    start_time = (
        now.replace(hour=0, minute=0, second=0, microsecond=0) - timedelta(days=30)
    ).timestamp()

    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute(
            """
            SELECT * FROM notifications 
            WHERE scheduled_time >= ?
            ORDER BY scheduled_time ASC
        """,
            (start_time,),
        )
        rows = cursor.fetchall()

    current_item_id = None
    for row in rows:
        if row["scheduled_time"] <= now_ts:
            current_item_id = row["id"]
        else:
            break

    notifications = []
    pending_count = 0

    for row in rows:
        dt = datetime.fromtimestamp(row["scheduled_time"], LOCAL_TZ)
        is_past = row["scheduled_time"] < now_ts and row["id"] != current_item_id
        is_current = row["id"] == current_item_id

        # Clean title matching your previous formatting[cite: 3]
        clean_title = row["title"].replace("Calendar: ", "")

        notifications.append(
            {
                "id": row["id"],
                "date_str": dt.strftime("%Y-%m-%d"),
                "time_str": dt.strftime("%H:%M"),
                "message": row["message"],
                "title": clean_title,
                "is_current": is_current,
                "is_past": is_past,
                "timestamp": row["scheduled_time"],
            }
        )
        if row["sent_at"] is None:
            pending_count += 1

    # Text view calculation for API/homelab backward compatibility[cite: 3]
    text_lines = []
    future_only = [
        n
        for n in notifications
        if n["timestamp"]
        >= (now.replace(hour=0, minute=0, second=0, microsecond=0).timestamp())
    ]

    for date, group in groupby(future_only, key=lambda x: x["date_str"]):
        text_lines.append(f"{date}:")
        for item in group:
            if item["is_current"]:
                text_lines.append(f"  ▶ {item['time_str']} {item['title']}")
            else:
                text_lines.append(f"    {item['time_str']} {item['title']}")
        text_lines.append("")

    next_event_str = "No events"
    future_events = [n for n in notifications if n["timestamp"] > now_ts]
    if future_events:
        n = future_events[0]
        next_event_str = f"{n['time_str']} {n['title']}"

    return {
        "count": pending_count,
        "text_view": "\n".join(text_lines).strip(),
        "next_event": next_event_str,
        "events": notifications,  # Passing raw data for the JS frontend
    }


@app.route("/api/calendar", methods=["GET"])
def api_calendar():
    data = get_zortex_calendar_view()
    return jsonify(data)


@app.route("/", methods=["GET"])
def home():
    """The calendar: the selected day's notifications and a month grid, under
    the top bar shared with the notes web app (zortex serve)."""
    data = get_zortex_calendar_view()
    notes = NOTES_URL.rstrip("/")
    return render_template_string(
        CALENDAR_HTML,
        count=data["count"],
        next_event=data["next_event"],
        site=SITE_TITLE,
        notes=notes,
        has_notes=bool(NOTES_URL),
    )


@app.route("/static/<name>", methods=["GET"])
def static_file(name):
    """The shared theme (style.css) and icon, from the notes app's files."""
    if name not in ("style.css", "icon.svg"):
        return jsonify({"error": "not found"}), 404
    path = os.path.join(STATIC_DIR, name)
    if not os.path.isfile(path):
        return jsonify({"error": "not found"}), 404
    response = send_file(path, max_age=3600)
    response.headers["X-Content-Type-Options"] = "nosniff"
    return response


# Shares the notes app's top bar (templates/layout.html) and stylesheet
# (web/static/style.css): brand, notes search, Files · Tags · Broken ·
# Calendar. Without NOTES_URL the notes links are left out.
CALENDAR_HTML = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Calendar · {{ site }}</title>
<link rel="stylesheet" href="/static/style.css">
<link rel="icon" href="/static/icon.svg" type="image/svg+xml">
<style>
  .cal-page { max-width: 64rem; margin: 0 auto; }
  .cal-head { display: flex; flex-wrap: wrap; align-items: baseline; gap: 0.4rem 1rem; margin: 0.4rem 0 1.1rem; }
  .cal-head h1 { margin: 0; font-size: 1.7rem; }
  .cal-head .dim { font-size: 0.9rem; }
  .cal-cols { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1.05fr); gap: 1rem; align-items: start; }
  .panel h2 { margin: 0.5rem 0 0.7rem; }
  .event-list { min-height: 6rem; padding-bottom: 0.3rem; }
  .event-item { display: flex; gap: 0.9rem; align-items: baseline; padding: 0.32rem 0; border-bottom: 1px solid color-mix(in srgb, var(--rule) 60%, transparent); }
  .event-item:last-child { border-bottom: 0; }
  .event-time { flex: none; min-width: 3.2rem; font-family: var(--mono); font-size: 0.86em; color: var(--accent); font-variant-numeric: tabular-nums; }
  .event-title { min-width: 0; overflow-wrap: anywhere; }
  .event-title.current { font-weight: 600; }
  .event-title.current::before { content: "▶ "; color: var(--accent); }
  .event-item.past .event-time, .event-item.past .event-title { color: var(--dim); }
  .empty-day { color: var(--dim); text-align: center; padding: 1.5rem 0 1rem; }
  .now-row { display: flex; align-items: center; gap: 0.6rem; margin: 0.15rem 0 0.15rem 1.2rem; height: 3.2rem; }
  .now-track { position: relative; width: 3px; height: 100%; border-radius: 2px; background: var(--rule); }
  .now-fill { position: absolute; inset: 0 0 auto 0; border-radius: 2px; background: var(--accent); }
  .now-label { font-family: var(--mono); font-size: 0.8rem; color: var(--accent); }
  .cal-controls { display: flex; justify-content: space-between; align-items: center; margin: 0.4rem 0 0.6rem; }
  .cal-controls h2 { margin: 0; }
  .cal-controls button, .day-cell { font: inherit; color: var(--ink); cursor: pointer; }
  .cal-controls button { background: var(--bg); border: 1px solid var(--rule); border-radius: 6px; padding: 0.15rem 0.65rem; }
  .cal-controls button:hover { border-color: var(--accent); color: var(--accent); }
  .calendar-grid { display: grid; grid-template-columns: repeat(7, 1fr); gap: 3px; text-align: center; }
  .weekday { color: var(--dim); font-size: 0.72rem; text-transform: uppercase; letter-spacing: 0.07em; padding: 0.2rem 0 0.35rem; }
  .day-cell { position: relative; background: none; border: 1px solid transparent; border-radius: 6px; padding: 0.5rem 0 0.6rem; font-variant-numeric: tabular-nums; }
  .day-cell:hover { background: var(--accent-soft); }
  .day-cell:focus-visible { outline: 2px solid var(--accent); outline-offset: -2px; }
  .day-cell.today { color: var(--accent); font-weight: 700; }
  .day-cell.active { border-color: var(--accent); background: var(--accent-soft); }
  .day-cell.has-events::after { content: ""; position: absolute; left: 50%; bottom: 0.22rem; width: 4px; height: 4px; margin-left: -2px; border-radius: 50%; background: var(--accent); }
  .day-cell.blank { visibility: hidden; }
  @media (max-width: 50rem) { .cal-cols { grid-template-columns: minmax(0, 1fr); } }
</style>
</head>
<body>
<header class="top">
  <a class="brand" href="{{ notes }}/">{{ site }}</a>
  {% if has_notes %}
  <form class="quick" action="{{ notes }}/search" method="get" role="search">
    <input type="search" name="q" placeholder="Search notes  ( / )" aria-label="Search notes" autocomplete="off" id="quick">
  </form>
  {% else %}<div class="quick"></div>{% endif %}
  <nav class="links">
    {% if has_notes %}
    <a href="{{ notes }}/f/">Files</a>
    <a href="{{ notes }}/tags">Tags</a>
    <a href="{{ notes }}/broken">Broken</a>
    {% endif %}
    <a href="/" aria-current="page">Calendar</a>
  </nav>
</header>
<main>
<section class="cal-page">
  <div class="cal-head">
    <h1>Calendar</h1>
    <span class="dim" id="stats">{{ count }} pending notification{{ "" if count == 1 else "s" }} · next: {{ next_event }}</span>
  </div>
  <div class="cal-cols">
    <div class="panel">
      <h2 id="day-header">Today</h2>
      <div class="event-list" id="event-list"></div>
    </div>
    <div class="panel">
      <div class="cal-controls">
        <button type="button" onclick="changeMonth(-1)" aria-label="Previous month">‹</button>
        <h2 id="month-label"></h2>
        <button type="button" onclick="changeMonth(1)" aria-label="Next month">›</button>
      </div>
      <div class="calendar-grid" aria-hidden="true">
        <div class="weekday">Su</div><div class="weekday">Mo</div><div class="weekday">Tu</div><div class="weekday">We</div>
        <div class="weekday">Th</div><div class="weekday">Fr</div><div class="weekday">Sa</div>
      </div>
      <div class="calendar-grid" id="calendar-days"></div>
    </div>
  </div>
</section>
</main>
<script>
(function () {
  "use strict";
  let events = [];
  const shown = new Date();      // month on display
  let selected = new Date();     // day on display
  const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const dayKey = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;

  function renderDay() {
    const key = dayKey(selected), today = key === dayKey(new Date());
    document.getElementById("day-header").textContent = today ? "Today"
      : selected.toLocaleDateString(undefined, { weekday: "long", month: "short", day: "numeric" });
    const list = document.getElementById("event-list");
    const day = events.filter((e) => e.date_str === key);
    if (!day.length) { list.innerHTML = '<div class="empty-day">Nothing scheduled.</div>'; return; }
    const now = Date.now();
    let html = "";
    day.forEach((e, i) => {
      html += `<div class="event-item${e.is_past ? " past" : ""}"><span class="event-time">${esc(e.time_str)}</span>` +
        `<span class="event-title${e.is_current ? " current" : ""}">${esc(e.title)}</span></div>`;
      // where "now" sits between the current entry and the next one today
      if (today && e.is_current && i + 1 < day.length) {
        const start = e.timestamp * 1000, end = day[i + 1].timestamp * 1000;
        const pct = end > start ? Math.max(0, Math.min(100, (now - start) / (end - start) * 100)) : 0;
        const label = new Date(now).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
        html += `<div class="now-row"><div class="now-track"><div class="now-fill" style="height:${pct}%"></div></div>` +
          `<span class="now-label">◀ ${esc(label)}</span></div>`;
      }
    });
    list.innerHTML = html;
  }

  function renderMonth() {
    const y = shown.getFullYear(), m = shown.getMonth();
    document.getElementById("month-label").textContent = shown.toLocaleDateString(undefined, { month: "long", year: "numeric" });
    const first = new Date(y, m, 1).getDay(), days = new Date(y, m + 1, 0).getDate();
    const busy = new Set(events.map((e) => e.date_str));
    const sel = dayKey(selected), today = dayKey(new Date());
    let html = '<span class="day-cell blank"></span>'.repeat(first);
    for (let d = 1; d <= days; d++) {
      const key = dayKey(new Date(y, m, d));
      const cls = ["day-cell", busy.has(key) && "has-events", key === sel && "active", key === today && "today"].filter(Boolean).join(" ");
      html += `<button type="button" class="${cls}" data-day="${d}" aria-label="${key}${busy.has(key) ? ", has events" : ""}">${d}</button>`;
    }
    document.getElementById("calendar-days").innerHTML = html;
  }

  document.getElementById("calendar-days").addEventListener("click", (ev) => {
    const b = ev.target.closest("button[data-day]");
    if (!b) return;
    selected = new Date(shown.getFullYear(), shown.getMonth(), Number(b.dataset.day));
    renderDay(); renderMonth();
  });
  window.changeMonth = (n) => { shown.setDate(1); shown.setMonth(shown.getMonth() + n); renderMonth(); };

  async function refresh() {
    try {
      const r = await fetch("/api/calendar");
      if (!r.ok) return;
      const data = await r.json();
      events = data.events || [];
      document.getElementById("stats").textContent =
        `${data.count} pending notification${data.count === 1 ? "" : "s"} · next: ${data.next_event}`;
      renderDay(); renderMonth();
    } catch (err) { console.error("calendar refresh failed", err); }
  }

  document.addEventListener("keydown", (e) => {
    const box = document.getElementById("quick");
    const el = document.activeElement;
    if (box && e.key === "/" && !(el && (el.tagName === "INPUT" || el.tagName === "TEXTAREA"))) { e.preventDefault(); box.focus(); }
  });

  refresh();
  setInterval(refresh, 30000);
})();
</script>
</body>
</html>
"""


# ==============================================================================
#  Notes: tree, search, file (read-only)
# ==============================================================================


def _notes_or_error():
    if NOTES is None:
        return None, (jsonify({"error": "NOTES_DIR is not set or does not exist"}), 404)
    return NOTES, None


def _flag(name, default="0"):
    return request.args.get(name, default).lower() in ("1", "true", "yes")


@app.route("/api/notes/tree", methods=["GET"])
def api_notes_tree():
    notes, err = _notes_or_error()
    if err:
        return err
    return jsonify(notes.tree(include_all=_flag("all"), files=_flag("files", "1")))


@app.route("/api/notes/search", methods=["GET"])
def api_notes_search():
    notes, err = _notes_or_error()
    if err:
        return err
    limit = min(int(request.args.get("limit", 50)), 200)
    return jsonify(
        notes.search(request.args.get("q", ""), include_all=_flag("all"), limit=limit, files=_flag("files", "1"))
    )


@app.route("/api/notes/file", methods=["GET"])
def api_notes_file():
    notes, err = _notes_or_error()
    if err:
        return err
    rel = request.args.get("path", "")
    if not rel.endswith(notes.extension):
        # Other files: their metadata; the content comes from /api/notes/raw
        entry = notes.entry(rel)
        if entry is None or notes.path_for(rel, any_file=True) is None:
            return jsonify({"error": "not found"}), 404
        return jsonify(entry.summary())
    lines = notes.read_lines(rel)
    if lines is None:
        return jsonify({"error": "not found"}), 404
    names = [l[2:].strip() for l in lines[:20] if l.startswith("@@")]
    return jsonify({"rel": rel, "kind": "note", "view": "zortex", "title": names[0] if names else rel, "lines": classify(lines)})


# Types a browser could run script in: served sandboxed so a file in the notes
# folder can't act on the dashboard's origin. (PDFs are not sandboxed: Chrome
# refuses to show PDFs in sandboxed documents.)
_ACTIVE_TYPES = ("text/html", "image/svg+xml", "application/xhtml+xml", "application/xml", "text/xml")


@app.route("/api/notes/raw", methods=["GET"])
def api_notes_raw():
    """Any file in the notes folder, as is: PDFs, images, video (with range
    requests), text. ?download=1 saves it instead of showing it."""
    notes, err = _notes_or_error()
    if err:
        return err
    rel = request.args.get("path", "")
    path = notes.path_for(rel, any_file=True)
    if path is None:
        return jsonify({"error": "not found"}), 404
    mime = guess_mime(path)
    if rel.endswith(notes.extension):
        mime = "text/plain; charset=utf-8"
    elif mime.startswith("text/") and "charset" not in mime:
        mime += "; charset=utf-8"
    response = send_file(
        path,
        mimetype=mime,
        conditional=True,
        as_attachment=_flag("download"),
        download_name=os.path.basename(path),
        max_age=60,
    )
    response.headers["X-Content-Type-Options"] = "nosniff"
    if mime.split(";")[0] in _ACTIVE_TYPES:
        response.headers["Content-Security-Policy"] = "sandbox"
    return response


@app.route("/api/summary", methods=["GET"])
def api_summary():
    """JSON Endpoint for Homelab Dashboards (Homepage, etc)"""
    data = get_zortex_calendar_view()
    return jsonify(
        {
            "status": "ok",
            "pending_count": data["count"],
            "calendar_text": data["text_view"],
            "calendar_html": "<pre>" + html_escape(data["text_view"]) + "</pre>",
            "next_event": data["next_event"],
            "generated_at": datetime.now(LOCAL_TZ).isoformat(),
        }
    )


# ==============================================================================
#  Standard API Routes
# ==============================================================================


@app.route("/health", methods=["GET"])
def health_check():
    """Health check endpoint"""
    return jsonify(
        {"status": "healthy", "timestamp": datetime.now(timezone.utc).isoformat()}
    )


@app.route("/notify", methods=["POST"])
def receive_notification():
    """Receive notification manifest from Zortex"""
    try:
        data = request.json
        if not data:
            return jsonify({"success": False, "error": "No data provided"}), 400

        user_id = data.get("user_id")
        operation = data.get("operation")

        if not user_id:
            return jsonify({"success": False, "error": "user_id required"}), 400

        if operation == "sync":
            # Handle bulk sync of notifications
            result = sync_notifications(user_id, data.get("notifications", []))
            return jsonify(result)

        elif operation == "notify":
            # Handle single notification
            notification = data.get("notification", {})
            result = add_notification(user_id, notification)
            return jsonify(result)

        elif operation == "clear":
            # Clear all pending notifications for user
            result = clear_user_notifications(user_id)
            return jsonify(result)

        else:
            return jsonify(
                {"success": False, "error": f"Unknown operation: {operation}"}
            ), 400

    except Exception as e:
        logger.error(f"Error processing notification: {e}")
        return jsonify({"success": False, "error": str(e)}), 500


def sync_notifications(user_id, notifications):
    """Sync a batch of notifications by diffing and upserting"""
    try:
        with get_db() as conn:
            cursor = conn.cursor()

            # 1. Compute keys for incoming notifications
            incoming_keys = []
            for notif in notifications:
                dedup_key = notif.get("deduplication_key")
                if not dedup_key and notif.get("entry_id"):
                    dedup_key = f"{notif['entry_id']}_{notif.get('scheduled_time', 0)}"
                notif["_computed_key"] = dedup_key
                if dedup_key:
                    incoming_keys.append(dedup_key)

            # 2. Delete pending notifications NOT in the new sync batch
            if incoming_keys:
                placeholders = ",".join(["?"] * len(incoming_keys))
                cursor.execute(
                    f"""
                    DELETE FROM notifications 
                    WHERE user_id = ? AND sent_at IS NULL 
                    AND deduplication_key NOT IN ({placeholders})
                """,
                    [user_id] + incoming_keys,
                )
            else:
                cursor.execute(
                    "DELETE FROM notifications WHERE user_id = ? AND sent_at IS NULL",
                    (user_id,),
                )

            # 3. Upsert incoming notifications
            added = 0
            skipped = 0
            current_time = int(datetime.now(timezone.utc).timestamp())

            for notif in notifications:
                try:
                    cursor.execute(
                        """
                        INSERT INTO notifications 
                        (user_id, entry_id, title, message, scheduled_time, 
                         priority, tags, created_at, deduplication_key)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(user_id, deduplication_key) DO UPDATE SET
                            title = excluded.title,
                            message = excluded.message,
                            scheduled_time = excluded.scheduled_time,
                            priority = excluded.priority,
                            tags = excluded.tags
                        WHERE notifications.sent_at IS NULL
                    """,
                        (
                            user_id,
                            notif.get("entry_id"),
                            notif.get("title", "Zortex Notification"),
                            notif.get("message", ""),
                            notif.get("scheduled_time", current_time),
                            notif.get("priority", "default"),
                            json.dumps(notif.get("tags", [])),
                            current_time,
                            notif["_computed_key"],
                        ),
                    )
                    added += 1
                except Exception as e:
                    logger.error(f"Error upserting notification: {e}")
                    skipped += 1

            logger.info(f"Synced notifications for {user_id}: {added} upserted")
            return {"success": True, "upserted": added, "total": len(notifications)}

    except Exception as e:
        logger.error(f"Error syncing notifications: {e}")
        return {"success": False, "error": str(e)}


def add_notification(user_id, notification):
    """Add a single notification"""
    try:
        with get_db() as conn:
            cursor = conn.cursor()

            dedup_key = notification.get("deduplication_key")
            if not dedup_key and notification.get("entry_id"):
                dedup_key = f"{notification['entry_id']}_{notification.get('scheduled_time', 0)}"

            cursor.execute(
                """
                INSERT INTO notifications 
                (user_id, entry_id, title, message, scheduled_time, 
                 priority, tags, created_at, deduplication_key)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
                (
                    user_id,
                    notification.get("entry_id"),
                    notification.get("title", "Zortex Notification"),
                    notification.get("message", ""),
                    notification.get(
                        "scheduled_time", int(datetime.now(timezone.utc).timestamp())
                    ),
                    notification.get("priority", "default"),
                    json.dumps(notification.get("tags", [])),
                    int(datetime.now(timezone.utc).timestamp()),
                    dedup_key,
                ),
            )

            logger.info(
                f"Added notification for {user_id}: {notification.get('title')}"
            )
            return {"success": True, "id": cursor.lastrowid}

    except sqlite3.IntegrityError:
        logger.debug(f"Duplicate notification skipped: {dedup_key}")
        return {"success": True, "message": "Duplicate notification skipped"}
    except Exception as e:
        logger.error(f"Error adding notification: {e}")
        return {"success": False, "error": str(e)}


def clear_user_notifications(user_id):
    """Clear all pending notifications for a user"""
    try:
        with get_db() as conn:
            cursor = conn.cursor()
            cursor.execute(
                """
                DELETE FROM notifications 
                WHERE user_id = ? AND sent_at IS NULL
            """,
                (user_id,),
            )

            deleted = cursor.rowcount
            logger.info(f"Cleared {deleted} pending notifications for {user_id}")
            return {"success": True, "deleted": deleted}

    except Exception as e:
        logger.error(f"Error clearing notifications: {e}")
        return {"success": False, "error": str(e)}


@app.route("/pending", methods=["GET"])
def get_pending_notifications():
    """Get pending notifications (for debugging)"""
    try:
        user_id = request.args.get("user_id")

        with get_db() as conn:
            cursor = conn.cursor()

            if user_id:
                cursor.execute(
                    """
                    SELECT * FROM notifications 
                    WHERE user_id = ? AND sent_at IS NULL
                    ORDER BY scheduled_time
                """,
                    (user_id,),
                )
            else:
                cursor.execute("""
                    SELECT * FROM notifications 
                    WHERE sent_at IS NULL
                    ORDER BY scheduled_time
                """)

            notifications = []
            for row in cursor.fetchall():
                notif = dict(row)
                notif["tags"] = json.loads(notif["tags"]) if notif["tags"] else []
                notif["scheduled_datetime"] = datetime.fromtimestamp(
                    notif["scheduled_time"], timezone.utc
                ).isoformat()
                notifications.append(notif)

            return jsonify(
                {
                    "success": True,
                    "count": len(notifications),
                    "notifications": notifications,
                }
            )

    except Exception as e:
        logger.error(f"Error getting pending notifications: {e}")
        return jsonify({"success": False, "error": str(e)}), 500


@app.route("/test", methods=["POST", "GET"])
def test_notification():
    """Test the complete notification flow end-to-end"""
    import subprocess
    import shutil

    try:
        # Allow both GET (for easy browser testing) and POST
        if request.method == "GET":
            # Simple test notification for GET requests
            user_id = request.args.get("user_id", "test-user")
            title = request.args.get("title", "Test Notification")
            message = request.args.get(
                "message", f"This is a test at {datetime.now(timezone.utc).isoformat()}"
            )
            delay = int(request.args.get("delay", 0))  # Delay in seconds before sending
        else:
            # POST with JSON body
            data = request.json or {}
            user_id = data.get("user_id", "test-user")
            title = data.get("title", "Test Notification")
            message = data.get(
                "message", f"This is a test at {datetime.now(timezone.utc).isoformat()}"
            )
            delay = int(data.get("delay", 0))

        # Calculate scheduled time
        scheduled_time = int(datetime.now(timezone.utc).timestamp()) + delay

        # Step 1: Add notification to database
        logger.info(f"TEST: Adding notification for {user_id}")

        # Use a more unique key for tests to avoid collisions on rapid retries
        import random

        random_suffix = random.randint(1000, 9999)
        dedup_key = (
            f"test_{int(datetime.now(timezone.utc).timestamp())}_{random_suffix}"
        )

        with get_db() as conn:
            cursor = conn.cursor()
            cursor.execute(
                """
                INSERT INTO notifications 
                (user_id, entry_id, title, message, scheduled_time, 
                 priority, tags, created_at, deduplication_key)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
                (
                    user_id,
                    "test-entry",
                    title,
                    message,
                    scheduled_time,
                    "high",  # High priority for test
                    json.dumps(["test", "manual"]),
                    int(datetime.now(timezone.utc).timestamp()),
                    f"test_{int(datetime.now(timezone.utc).timestamp())}",  # Unique key
                ),
            )

            notification_id = cursor.lastrowid
            logger.info(f"TEST: Created notification with ID {notification_id}")

        # Step 2: Run the notification sender script
        # We will assume 'zortex-sender' is in the PATH in the nix package
        script_cmd = ["zortex-sender"]

        # If not found (local dev), fallback to ./send.sh
        if not shutil.which("zortex-sender"):
            script_cmd = ["/bin/bash", "./send.sh"]

        logger.info(f"TEST: Triggering {script_cmd} to send notification")

        try:
            result = subprocess.run(
                script_cmd, capture_output=True, text=True, timeout=10
            )

            logger.info(f"TEST: script exit code: {result.returncode}")
            if result.stdout:
                logger.info(f"TEST: stdout: {result.stdout}")
            if result.stderr:
                logger.error(f"TEST: stderr: {result.stderr}")

            run_success = result.returncode == 0
            run_output = result.stdout + result.stderr
        except subprocess.TimeoutExpired:
            run_success = False
            run_output = "Timeout waiting for script"
            logger.error("TEST: script timed out")
        except Exception as e:
            run_success = False
            run_output = str(e)
            logger.error(f"TEST: Error running script: {e}")

        # Step 3: Check if notification was sent
        with get_db() as conn:
            cursor = conn.cursor()
            cursor.execute(
                """
                SELECT sent_at FROM notifications WHERE id = ?
            """,
                (notification_id,),
            )

            row = cursor.fetchone()
            was_sent = row and row["sent_at"] is not None

        # Prepare response
        response_data = {
            "success": True,
            "test_results": {
                "notification_id": notification_id,
                "scheduled_time": datetime.fromtimestamp(
                    scheduled_time, timezone.utc
                ).isoformat(),
                "delay_seconds": delay,
                "database_insert": "success",
                "run_script_executed": run_success,
                "run_script_output": run_output[:500] if run_output else None,
                "notification_sent": was_sent,
                "overall_status": "SUCCESS" if was_sent else "FAILED",
            },
            "message": f"Test {'completed successfully' if was_sent else 'failed - check logs'}. Check your ntfy app for: '{title}'",
        }

        logger.info(
            f"TEST: Overall result: {response_data['test_results']['overall_status']}"
        )

        return jsonify(response_data)

    except Exception as e:
        logger.error(f"Error in test endpoint: {e}")
        return jsonify(
            {
                "success": False,
                "error": str(e),
                "test_results": {"overall_status": "ERROR"},
            }
        ), 500


if __name__ == "__main__":
    init_database()
    logger.info(f"Starting Zortex notification server on port {FLASK_PORT}")
    app.run(host="0.0.0.0", port=FLASK_PORT, debug=(LOG_LEVEL == "DEBUG"))
