#!/usr/bin/env python3
# app/server.py
import os
import sqlite3
import json
import logging
from datetime import datetime, timezone, timedelta
from itertools import groupby
from flask import Flask, request, jsonify, render_template_string
from contextlib import contextmanager
from zoneinfo import ZoneInfo

from notes import NotesIndex, classify, DEFAULT_SPECIAL

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
    """Render the 'Homey' Zortex Homepage with interactive calendar"""
    data = get_zortex_calendar_view()

    html = r"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Zortex Hub</title>
        <style>
            :root {
                --bg: #1e1e2e;
                --fg: #cdd6f4;
                --accent: #89b4fa;
                --surface: #313244;
                --surface-hover: #45475a;
                --green: #a6e3a1;
                --dim: rgba(205, 214, 244, 0.4);
            }
            body {
                background-color: var(--bg);
                color: var(--fg);
                font-family: 'JetBrains Mono', 'Fira Code', monospace;
                margin: 0;
                padding: 2rem;
                display: flex;
                flex-direction: column;
                align-items: center;
                min-height: 100vh;
            }
            .container {
                max-width: 600px;
                width: 100%;
            }
            .container.wide { max-width: 1100px; }
            .tabs { display: flex; justify-content: center; gap: 0.5rem; margin-bottom: 1.5rem; }
            .tabs button {
                background: none; color: var(--fg); border: 1px solid var(--surface-hover);
                padding: 0.4rem 1.2rem; border-radius: 4px; cursor: pointer; font: inherit;
            }
            .tabs button.active { border-color: var(--accent); color: var(--accent); }
            .hidden { display: none !important; }

            /* Notes */
            .notes-layout { display: grid; grid-template-columns: minmax(220px, 1fr) 2fr; gap: 1.5rem; }
            @media (max-width: 800px) { .notes-layout { grid-template-columns: 1fr; } }
            .notes-search { display: flex; gap: 0.75rem; align-items: center; margin-bottom: 1rem; }
            .notes-search input[type=search] {
                flex: 1; background: var(--bg); color: var(--fg); border: 1px solid var(--surface-hover);
                border-radius: 4px; padding: 0.5rem 0.75rem; font: inherit;
            }
            .notes-search label { font-size: 0.8rem; opacity: 0.7; white-space: nowrap; }
            .tree, .results { font-size: 0.9rem; }
            .tree details { margin-left: 0.75rem; }
            .tree summary { cursor: pointer; color: var(--accent); }
            .note-link { display: block; padding: 2px 0 2px 0.75rem; cursor: pointer; color: var(--fg); text-decoration: none; }
            .note-link:hover { color: var(--accent); }
            .note-link.archived { opacity: 0.45; }
            .note-link .meta { opacity: 0.45; font-size: 0.8em; margin-left: 0.4rem; }
            .results h3 { font-size: 0.8rem; opacity: 0.6; text-transform: uppercase; margin: 0.75rem 0 0.25rem; }
            .line-hit .loc { opacity: 0.45; font-size: 0.8em; }
            .viewer { white-space: pre-wrap; font-size: 0.9rem; line-height: 1.45; overflow-x: auto; }
            .viewer .ln { display: block; padding: 0 0.25rem; }
            .viewer .ln.target { background: rgba(137, 180, 250, 0.15); }
            .k-article { color: #c4a7e7; font-weight: bold; }
            .k-tag { color: #ea9a97; }
            .k-heading { color: #eb6f92; font-weight: bold; }
            .k-heading.h2 { color: #ea9a97; } .k-heading.h3 { color: #f6c177; }
            .k-bold_heading { color: #56949f; font-weight: bold; }
            .k-label { color: #3e8fb0; font-weight: bold; }
            .k-task { color: #f6c177; }
            .k-task_done { color: #908caa; text-decoration: line-through; }
            .k-code, .k-fence { color: #f2ae49; background: rgba(0,0,0,0.2); }
            .k-quote, .k-table { color: #908caa; }
            .viewer .zl { color: #3e8fb0; }
            .viewer .attr { color: #908caa; font-style: italic; }
            h1 { color: var(--accent); margin-bottom: 0.5rem; text-align: center; }
            .stats {
                color: var(--green);
                font-size: 0.9rem;
                margin-bottom: 2rem;
                opacity: 0.8;
                text-align: center;
            }
            .card {
                background-color: var(--surface);
                padding: 1.5rem;
                border-radius: 8px;
                box-shadow: 0 4px 6px rgba(0,0,0,0.1);
                margin-bottom: 1.5rem;
            }
            .day-header {
                font-size: 1.2rem;
                font-weight: bold;
                margin-bottom: 1rem;
                color: var(--accent);
                border-bottom: 1px solid var(--surface-hover);
                padding-bottom: 0.5rem;
            }
            .event-list {
                display: flex;
                flex-direction: column;
                gap: 0.5rem;
                min-height: 100px;
            }
            .event-item {
                display: flex;
                gap: 1rem;
            }
            .event-time { opacity: 0.7; min-width: 50px; }
            .event-title.current { color: var(--accent); font-weight: bold; }
            .event-title.past { opacity: 0.4; }
            
            /* Calendar Grid Styles */
            .calendar-controls {
                display: flex;
                justify-content: space-between;
                align-items: center;
                margin-bottom: 1rem;
            }
            .calendar-controls button {
                background: none;
                border: 1px solid var(--surface-hover);
                color: var(--fg);
                padding: 0.5rem 1rem;
                border-radius: 4px;
                cursor: pointer;
            }
            .calendar-controls button:hover { background: var(--surface-hover); }
            .calendar-grid {
                display: grid;
                grid-template-columns: repeat(7, 1fr);
                gap: 5px;
                text-align: center;
            }
            .weekday { font-weight: bold; opacity: 0.6; padding-bottom: 0.5rem; }
            .day-cell {
                padding: 0.75rem 0;
                border-radius: 4px;
                cursor: pointer;
                border: 1px solid transparent;
                position: relative;
            }
            .day-cell:hover { background-color: var(--surface-hover); }
            .day-cell.active { border-color: var(--accent); background-color: rgba(137, 180, 250, 0.1); }
            .day-cell.has-events::after {
                content: '';
                position: absolute;
                bottom: 4px;
                left: 50%;
                transform: translateX(-50%);
                width: 4px;
                height: 4px;
                border-radius: 50%;
                background-color: var(--accent);
            }
            .day-cell.empty { visibility: hidden; }

            /* Progress bar styles */
            .progress-wrapper {
                display: flex;
                height: 60px;
                margin-left: 20px;
                padding: 4px 0;
                position: relative;
            }
            .vertical-track {
                width: 4px;
                height: 100%;
                background-color: var(--surface-hover);
                border-radius: 2px;
                position: relative;
                margin-right: 15px;
            }
            .vertical-progress {
                width: 100%;
                background-color: var(--accent);
                border-radius: 2px;
                position: absolute;
                top: 0;
                left: 0;
                transition: height 0.5s ease;
            }
            .current-time-label {
                font-size: 0.85rem;
                color: var(--accent);
                position: absolute;
                left: 25px;
                top: var(--progress-percent);
                transform: translateY(-70%);
                display: flex;
                align-items: center;
                gap: 5px;
                transition: top 0.5s ease;
            }
        </style>
    </head>
    <body>
        <div class="container">
            <h1>Zortex Hub</h1>
            <div class="stats" id="stats">
                System Online • {{ count }} Pending Notifications
            </div>

            <div class="tabs">
                <button id="tab-calendar" class="active" onclick="showTab('calendar')">Calendar</button>
                <button id="tab-notes" onclick="showTab('notes')">Notes</button>
            </div>

            <!-- Notes tab: search, folder tree, viewer -->
            <div id="notes-tab" class="hidden">
                <div class="card">
                    <div class="notes-search">
                        <input type="search" id="notes-query" placeholder="Search notes (names, aliases, tags, paths, lines)" autocomplete="off">
                        <label><input type="checkbox" id="notes-all"> all top-level notes</label>
                    </div>
                    <div class="notes-layout">
                        <div>
                            <div class="results" id="notes-results"></div>
                            <div class="tree" id="notes-tree"></div>
                        </div>
                        <div class="viewer" id="notes-viewer"><span style="opacity:0.5">Pick a note.</span></div>
                    </div>
                </div>
            </div>

            <div id="calendar-tab">
            <!-- Daily List View -->
            <div class="card" id="list-view">
                <div class="day-header" id="selected-date-header">Loading...</div>
                <div class="event-list" id="event-list-container"></div>
            </div>

            <!-- Navigable Calendar View -->
            <div class="card" id="calendar-view">
                <div class="calendar-controls">
                    <button onclick="changeMonth(-1)">&lt; Prev</button>
                    <div id="current-month-label" style="font-weight: bold;"></div>
                    <button onclick="changeMonth(1)">Next &gt;</button>
                </div>
                <div class="calendar-grid">
                    <div class="weekday">Su</div><div class="weekday">Mo</div>
                    <div class="weekday">Tu</div><div class="weekday">We</div>
                    <div class="weekday">Th</div><div class="weekday">Fr</div>
                    <div class="weekday">Sa</div>
                </div>
                <div class="calendar-grid" id="calendar-days"></div>
            </div>
            </div>
        </div>

        <script>
            let events = [];
            let currentDate = new Date();
            let selectedDate = new Date(); // Defaults to today
            
            const localTzOffset = currentDate.getTimezoneOffset() * 60000;

            function formatDateStr(date) {
                // Returns YYYY-MM-DD in local time
                const d = new Date(date.getTime() - localTzOffset);
                return d.toISOString().split('T')[0];
            }

            function renderDayList() {
                const header = document.getElementById('selected-date-header');
                const container = document.getElementById('event-list-container');
                
                const dateStr = formatDateStr(selectedDate);
                const isToday = dateStr === formatDateStr(new Date());
                
                header.textContent = isToday ? "Today's Events" : selectedDate.toLocaleDateString('en-US', { weekday: 'long', month: 'short', day: 'numeric' });
                
                const dayEvents = events.filter(e => e.date_str === dateStr);
                
                let htmlOutput = '';
                if (dayEvents.length === 0) {
                    htmlOutput = '<div style="opacity: 0.5; text-align: center; margin-top: 1rem;">No events scheduled for this day.</div>';
                    container.innerHTML = htmlOutput;
                    return;
                }

                const now = new Date();
                const nowMs = now.getTime();

                dayEvents.forEach((e, index) => {
                    let titleClass = "event-title";
                    let prefix = "";
                    if (e.is_current) { titleClass += " current"; prefix = "▶ "; }
                    else if (e.is_past) { titleClass += " past"; }

                    htmlOutput += `
                        <div class="event-item">
                            <div class="event-time">${e.time_str}</div>
                            <div class="${titleClass}">${prefix}${e.title.replace('<', '&lt;')}</div>
                        </div>
                    `;

                    // Inject progress bar if this is the active event and there is a subsequent event today
                    if (isToday && e.is_current && index + 1 < dayEvents.length) {
                        const nextE = dayEvents[index + 1];
                        const currentMs = e.timestamp * 1000;
                        const nextMs = nextE.timestamp * 1000;
                        
                        const totalDuration = nextMs - currentMs;
                        let percent = 0;
                        if (totalDuration > 0) {
                            percent = Math.max(0, Math.min(100, ((nowMs - currentMs) / totalDuration) * 100));
                        }
                        
                        const timeString = now.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });

                        htmlOutput += `
                            <div class="progress-wrapper" style="--progress-percent: ${percent}%;">
                                <div class="vertical-track">
                                    <div class="vertical-progress" style="height: ${percent}%;"></div>
                                </div>
                                <div class="current-time-label">◀ ${timeString}</div>
                            </div>
                        `;
                    }
                });
                
                container.innerHTML = htmlOutput;
            }

            function renderCalendar() {
                const container = document.getElementById('calendar-days');
                const monthLabel = document.getElementById('current-month-label');
                
                const year = currentDate.getFullYear();
                const month = currentDate.getMonth();
                
                monthLabel.textContent = currentDate.toLocaleDateString('en-US', { month: 'long', year: 'numeric' });
                
                const firstDay = new Date(year, month, 1).getDay();
                const daysInMonth = new Date(year, month + 1, 0).getDate();
                
                container.innerHTML = '';
                
                // Empty slots before 1st of month
                for (let i = 0; i < firstDay; i++) {
                    container.innerHTML += '<div class="day-cell empty"></div>';
                }
                
                const selectedStr = formatDateStr(selectedDate);
                const todayStr = formatDateStr(new Date());

                for (let day = 1; day <= daysInMonth; day++) {
                    const iterDate = new Date(year, month, day);
                    const iterStr = formatDateStr(iterDate);
                    
                    const hasEvents = events.some(e => e.date_str === iterStr);
                    const isActive = iterStr === selectedStr;
                    
                    let classes = "day-cell";
                    if (hasEvents) classes += " has-events";
                    if (isActive) classes += " active";

                    container.innerHTML += `
                        <div class="${classes}" onclick="selectDate(${year}, ${month}, ${day})">
                            ${day}
                        </div>
                    `;
                }
            }

            function selectDate(year, month, day) {
                selectedDate = new Date(year, month, day);
                renderDayList();
                renderCalendar();
            }

            function changeMonth(offset) {
                currentDate.setMonth(currentDate.getMonth() + offset);
                renderCalendar();
            }

            async function fetchData() {
                try {
                    const response = await fetch('/api/calendar');
                    if (!response.ok) return;
                    const data = await response.json();
                    
                    events = data.events || [];
                    document.getElementById('stats').textContent = `System Online • ${data.count} Pending Notifications`;
                    
                    renderDayList();
                    renderCalendar();
                } catch (err) {
                    console.error('Failed to fetch calendar data:', err);
                }
            }

            // ---------------------------------------------------------------
            // Notes tab
            // ---------------------------------------------------------------
            const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
            let notesLoaded = false, searchTimer = null;

            function showTab(name) {
                const notes = name === 'notes';
                document.getElementById('notes-tab').classList.toggle('hidden', !notes);
                document.getElementById('calendar-tab').classList.toggle('hidden', notes);
                document.getElementById('tab-notes').classList.toggle('active', notes);
                document.getElementById('tab-calendar').classList.toggle('active', !notes);
                document.querySelector('.container').classList.toggle('wide', notes);
                if (notes && !notesLoaded) { notesLoaded = true; loadTree(); }
                if (!location.hash.startsWith('#' + name)) history.replaceState(null, '', '#' + name);
            }

            const allFlag = () => document.getElementById('notes-all').checked ? '1' : '0';

            function noteLink(n) {
                const meta = n.names && n.names.length > 1 ? n.names.slice(1).join(', ') : '';
                return `<a class="note-link ${n.archived ? 'archived' : ''}" onclick="openNote('${encodeURIComponent(n.rel)}')">` +
                    `${esc(n.title)}<span class="meta">${esc(n.rel)}${meta ? ' · ' + esc(meta) : ''}</span></a>`;
            }

            function renderFolder(f, open) {
                let html = f.notes.map(noteLink).join('');
                for (const d of f.dirs) {
                    html += `<details ${open ? 'open' : ''}><summary>${esc(d.name)}/</summary>${renderFolder(d, false)}</details>`;
                }
                return html;
            }

            async function loadTree() {
                const el = document.getElementById('notes-tree');
                const res = await fetch('/api/notes/tree?all=' + allFlag());
                if (!res.ok) { el.innerHTML = '<span style="opacity:0.6">Notes are not configured (set NOTES_DIR).</span>'; return; }
                el.innerHTML = renderFolder(await res.json(), true);
            }

            async function runSearch() {
                const q = document.getElementById('notes-query').value.trim();
                const el = document.getElementById('notes-results');
                const tree = document.getElementById('notes-tree');
                if (!q) { el.innerHTML = ''; tree.classList.remove('hidden'); return; }
                tree.classList.add('hidden');
                const res = await fetch(`/api/notes/search?q=${encodeURIComponent(q)}&all=${allFlag()}`);
                if (!res.ok) return;
                const data = await res.json();
                let html = `<h3>Notes (${data.notes.length})</h3>` + (data.notes.map(noteLink).join('') || '<span style="opacity:0.5">none</span>');
                if (data.lines.length) {
                    html += `<h3>Lines (${data.lines.length})</h3>` + data.lines.map(l =>
                        `<a class="note-link line-hit" onclick="openNote('${encodeURIComponent(l.rel)}', ${l.lnum})">${esc(l.text)}` +
                        `<span class="loc"> ${esc(l.title)}:${l.lnum}</span></a>`).join('');
                }
                el.innerHTML = html;
            }

            function inline(text) {
                return esc(text)
                    .replace(/\[([^\]]+)\]/g, '<span class="zl">[$1]</span>')
                    .replace(/(^|\s)(@\w+(\([^)]*\))?)/g, '$1<span class="attr">$2</span>');
            }

            async function openNote(encRel, lnum) {
                const rel = decodeURIComponent(encRel);
                const res = await fetch('/api/notes/file?path=' + encodeURIComponent(rel));
                const el = document.getElementById('notes-viewer');
                if (!res.ok) { el.textContent = 'Not found: ' + rel; return; }
                const note = await res.json();
                el.innerHTML = note.lines.map((l, i) => {
                    const cls = `ln k-${l.kind}${l.level ? ' h' + l.level : ''}${lnum === i + 1 ? ' target' : ''}`;
                    const body = (l.kind === 'code' || l.kind === 'fence') ? esc(l.text) : inline(l.text);
                    return `<span class="${cls}" id="L${i + 1}">${body || ' '}</span>`;
                }).join('');
                history.replaceState(null, '', `#notes/${rel}${lnum ? ':' + lnum : ''}`);
                const target = lnum && document.getElementById('L' + lnum);
                if (target) target.scrollIntoView({ block: 'center' });
            }

            document.getElementById('notes-query').addEventListener('input', () => {
                clearTimeout(searchTimer);
                searchTimer = setTimeout(runSearch, 150);
            });
            document.getElementById('notes-all').addEventListener('change', () => { loadTree(); runSearch(); });

            if (location.hash.startsWith('#notes')) {
                showTab('notes');
                const m = location.hash.match(/^#notes\/(.+?)(?::(\d+))?$/);
                if (m) openNote(encodeURIComponent(m[1]), m[2] ? Number(m[2]) : undefined);
            }

            // Initial fetch and polling setup
            fetchData();
            setInterval(fetchData, 30000); // 30s refresh[cite: 3]
        </script>
    </body>
    </html>
    """
    # Note: Ensure you import timedelta from datetime at the top of server.py
    return render_template_string(html, count=data["count"])


# ==============================================================================
#  Notes: tree, search, file (read-only)
# ==============================================================================


def _notes_or_error():
    if NOTES is None:
        return None, (jsonify({"error": "NOTES_DIR is not set or does not exist"}), 404)
    return NOTES, None


def _flag(name):
    return request.args.get(name, "0").lower() in ("1", "true", "yes")


@app.route("/api/notes/tree", methods=["GET"])
def api_notes_tree():
    notes, err = _notes_or_error()
    if err:
        return err
    return jsonify(notes.tree(include_all=_flag("all")))


@app.route("/api/notes/search", methods=["GET"])
def api_notes_search():
    notes, err = _notes_or_error()
    if err:
        return err
    limit = min(int(request.args.get("limit", 50)), 200)
    return jsonify(notes.search(request.args.get("q", ""), include_all=_flag("all"), limit=limit))


@app.route("/api/notes/file", methods=["GET"])
def api_notes_file():
    notes, err = _notes_or_error()
    if err:
        return err
    rel = request.args.get("path", "")
    lines = notes.read_lines(rel)
    if lines is None:
        return jsonify({"error": "not found"}), 404
    names = [l[2:].strip() for l in lines[:20] if l.startswith("@@")]
    return jsonify({"rel": rel, "title": names[0] if names else rel, "lines": classify(lines)})


@app.route("/api/summary", methods=["GET"])
def api_summary():
    """JSON Endpoint for Homelab Dashboards (Homepage, etc)"""
    data = get_zortex_calendar_view()
    return jsonify(
        {
            "status": "ok",
            "pending_count": data["count"],
            "calendar_text": data["text_view"],
            "calendar_html": data["html_view"],
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
