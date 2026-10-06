#!/usr/bin/env python3
# deployment/server.py
import os
import sqlite3
import json
import logging
from datetime import datetime, timezone
from itertools import groupby
from flask import Flask, request, jsonify, render_template_string
from contextlib import contextmanager
from zoneinfo import ZoneInfo

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
    """Generates the text-based and HTML calendar view and stats"""
    now = datetime.now(LOCAL_TZ)
    now_ts = now.timestamp()

    # Calculate midnight today so we get ALL events for the current day
    start_of_today = now.replace(hour=0, minute=0, second=0, microsecond=0).timestamp()

    with get_db() as conn:
        cursor = conn.cursor()
        # Fetch everything from today onward, ignoring whether it was sent
        cursor.execute(
            """
            SELECT * FROM notifications 
            WHERE scheduled_time >= ?
            ORDER BY scheduled_time ASC
        """,
            (start_of_today,),
        )
        rows = cursor.fetchall()

    # Find the current active item (the last one scheduled before 'now')
    current_item_id = None
    for row in rows:
        if row["scheduled_time"] <= now_ts:
            current_item_id = row["id"]
        else:
            break  # Stop checking once we hit the future

    notifications = []
    pending_count = 0
    for row in rows:
        dt = datetime.fromtimestamp(row["scheduled_time"], LOCAL_TZ)
        notifications.append(
            {
                "id": row["id"],
                "date_str": dt.strftime("%Y-%m-%d"),
                "time_str": dt.strftime("%H:%M"),
                "title": row["title"],
                "is_current": row["id"] == current_item_id,
                "is_past": row["scheduled_time"] < now_ts
                and row["id"] != current_item_id,
                "obj": row,
            }
        )
        if row["sent_at"] is None:
            pending_count += 1

    # Generate both plain text and HTML blocks
    text_lines = []
    html_lines = []

    for date, group in groupby(notifications, key=lambda x: x["date_str"]):
        text_lines.append(f"{date}:")
        html_lines.append(f"{date}:")

        for item in group:
            clean_title = item["title"].replace("Calendar: ", "")
            # Basic escape so HTML doesn't break if a title contains < or >
            safe_title = clean_title.replace("<", "&lt;").replace(">", "&gt;")

            if item["is_current"]:
                # Arrow indicator for text, bold + accent color + arrow for HTML
                text_lines.append(f"  ▶ {item['time_str']} {clean_title}")
                html_lines.append(
                    f"  <b style='color: var(--accent);'>▶ {item['time_str']} {safe_title}</b>"
                )
            elif item["is_past"]:
                # Dim past events in HTML
                text_lines.append(f"    {item['time_str']} {clean_title}")
                html_lines.append(
                    f"  <span style='opacity: 0.4;'>  {item['time_str']} {safe_title}</span>"
                )
            else:
                text_lines.append(f"    {item['time_str']} {clean_title}")
                html_lines.append(f"    {item['time_str']} {safe_title}")

        text_lines.append("")
        html_lines.append("")

    # Calculate next upcoming event
    next_event_str = "No events"
    future_events = [n for n in notifications if n["obj"]["scheduled_time"] > now_ts]
    if future_events:
        n = future_events[0]
        clean_title = n["title"].replace("Calendar: ", "")
        next_event_str = f"{n['time_str']} {clean_title}"

    return {
        "count": pending_count,
        "text_view": "\n".join(text_lines).strip(),
        "html_view": "\n".join(html_lines).strip(),
        "next_event": next_event_str,
    }


@app.route("/api/calendar", methods=["GET"])
def api_calendar():
    data = get_zortex_calendar_view()
    return jsonify(data)


@app.route("/", methods=["GET"])
def home():
    """Render the 'Homey' Zortex Homepage"""
    data = get_zortex_calendar_view()

    html = """
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
                --green: #a6e3a1;
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
                max-width: 800px;
                width: 100%;
            }
            h1 { color: var(--accent); margin-bottom: 0.5rem; }
            .stats {
                color: var(--green);
                font-size: 0.9rem;
                margin-bottom: 2rem;
                opacity: 0.8;
            }
            .card {
                background-color: var(--surface);
                padding: 1.5rem;
                border-radius: 8px;
                box-shadow: 0 4px 6px rgba(0,0,0,0.1);
                overflow-x: auto;
            }
            pre {
                margin: 0;
                font-size: 0.95rem;
                line-height: 1.5;
            }
        </style>
    </head>
    <body>
        <div class="container">
            <h1>Zortex Hub</h1>
            <div class="stats" id="stats">
                System Online • {{ count }} Pending Notifications
            </div>
            
            <div class="card">
                <!-- Using the safe HTML view here so we get bolding and dimming -->
                <pre id="calendar-view">
{{ html_view | safe }}
                </pre>
            </div>
        </div>
        <script>
            async function refreshCalendar() {
                try {
                    const response = await fetch('/api/calendar');
                    if (!response.ok) return;
                    const data = await response.json();
                    
                    document.getElementById('stats').textContent = 
                        `System Online • ${data.count} Pending Notifications`;
                    
                    // Replaced textContent with innerHTML to allow styling
                    document.getElementById('calendar-view').innerHTML = data.html_view;
                } catch (err) {
                    console.error('Failed to update calendar:', err);
                }
            }

            // Poll every 30 seconds (30,000 ms)
            setInterval(refreshCalendar, 30000);
        </script>
    </body>
    </html>
    """
    return render_template_string(
        html, count=data["count"], html_view=data["html_view"]
    )


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
