#!/usr/bin/env python3
"""
Zortex Homelab Server
Complete server for notifications and digest with authentication
"""

import os
import json
import sqlite3
import hashlib
import secrets
import schedule
import threading
import time
import requests
from datetime import datetime, timedelta
from functools import wraps
from flask import Flask, render_template_string, request, jsonify, Response
import boto3

app = Flask(__name__)
app.config["SECRET_KEY"] = os.environ.get("SECRET_KEY", secrets.token_hex(32))

# Configuration
CONFIG = {
    "db_path": os.environ.get("DB_PATH", "/data/zortex.db"),
    "port": int(os.environ.get("PORT", 5000)),
    "api_key": os.environ.get("API_KEY", "change-me-please"),
    "api_key_hash": hashlib.sha256(
        os.environ.get("API_KEY", "change-me-please").encode()
    ).hexdigest(),
    "basic_auth_user": os.environ.get("BASIC_AUTH_USER", "admin"),
    "basic_auth_pass": os.environ.get("BASIC_AUTH_PASS", "admin"),
    "ntfy_url": os.environ.get("NTFY_URL", "http://localhost:8080"),
    "ntfy_topic": os.environ.get("NTFY_TOPIC", "zortex"),
    "email_enabled": os.environ.get("EMAIL_ENABLED", "false").lower() == "true",
    "ses_region": os.environ.get("SES_REGION", "us-east-1"),
    "from_email": os.environ.get("FROM_EMAIL", "digest@example.com"),
    "to_email": os.environ.get("TO_EMAIL", "user@example.com"),
    "check_interval": int(os.environ.get("CHECK_INTERVAL", 60)),  # seconds
}

# HTML Template for digest (same as before, omitted for brevity)
DIGEST_TEMPLATE = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Zortex - {{ date }}</title>
    <style>
        :root {
            --bg-primary: #0a0a0a;
            --bg-secondary: #1a1a1a;
            --bg-hover: #2a2a2a;
            --text-primary: #e0e0e0;
            --text-secondary: #999;
            --accent: #3b82f6;
            --success: #10b981;
            --warning: #f59e0b;
            --danger: #ef4444;
            --border: #333;
        }
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: var(--bg-primary);
            color: var(--text-primary);
            line-height: 1.6;
        }
        .container { max-width: 900px; margin: 0 auto; padding: 2rem; }
        .header { border-bottom: 1px solid var(--border); padding-bottom: 1rem; margin-bottom: 2rem; }
        .header h1 { font-size: 2rem; font-weight: 300; }
        .section {
            background: var(--bg-secondary);
            border-radius: 8px;
            padding: 1.5rem;
            margin-bottom: 1.5rem;
        }
        .section h2 {
            font-size: 1.25rem;
            margin-bottom: 1rem;
            padding-bottom: 0.5rem;
            border-bottom: 1px solid var(--border);
        }
        .task-item, .event-item {
            padding: 0.75rem;
            margin: 0.5rem 0;
            background: var(--bg-primary);
            border-radius: 6px;
        }
        .nav-days {
            display: flex;
            gap: 0.5rem;
            margin-top: 2rem;
        }
        .nav-days a {
            padding: 0.5rem 1rem;
            background: var(--bg-secondary);
            color: var(--text-primary);
            text-decoration: none;
            border-radius: 4px;
        }
        .nav-days a.current { background: var(--accent); }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>Zortex Digest</h1>
            <div>{{ formatted_date }}</div>
        </div>
        {% for section in sections %}
        <div class="section">
            <h2>{{ section.title }}</h2>
            {% if section.items %}
                {% for item in section.items %}
                <div class="task-item">{{ item.text or item.title }}</div>
                {% endfor %}
            {% endif %}
        </div>
        {% endfor %}
    </div>
</body>
</html>
"""


class Database:
    """Unified database for notifications and digests"""

    def __init__(self, db_path):
        self.db_path = db_path
        self.init_db()

    def init_db(self):
        with sqlite3.connect(self.db_path) as conn:
            # Notifications table
            conn.execute("""
                CREATE TABLE IF NOT EXISTS notifications (
                    id TEXT PRIMARY KEY,
                    user_id TEXT,
                    entry_id TEXT,
                    title TEXT,
                    message TEXT,
                    trigger_time INTEGER,
                    repeat_pattern TEXT,
                    repeat_interval INTEGER,
                    last_sent INTEGER,
                    occurrence_count INTEGER DEFAULT 0,
                    active INTEGER DEFAULT 1,
                    priority TEXT,
                    tags TEXT,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            """)

            # Digests table
            conn.execute("""
                CREATE TABLE IF NOT EXISTS digests (
                    date TEXT PRIMARY KEY,
                    data TEXT,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            """)

            # Create indices for efficient queries
            conn.execute("""
                CREATE INDEX IF NOT EXISTS idx_notifications_trigger 
                ON notifications(active, trigger_time)
            """)
            conn.execute("""
                CREATE INDEX IF NOT EXISTS idx_notifications_entry 
                ON notifications(user_id, entry_id)
            """)


db = Database(CONFIG["db_path"])


# Authentication decorator
def require_auth(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        auth = request.authorization
        api_key = request.headers.get("X-API-Key")

        # Check API key for API endpoints
        if request.path.startswith("/api/"):
            if (
                not api_key
                or hashlib.sha256(api_key.encode()).hexdigest()
                != CONFIG["api_key_hash"]
            ):
                return jsonify({"error": "Invalid API key"}), 401
        # Check basic auth for web interface
        elif (
            not auth
            or auth.username != CONFIG["basic_auth_user"]
            or auth.password != CONFIG["basic_auth_pass"]
        ):
            return Response(
                "Authentication required",
                401,
                {"WWW-Authenticate": 'Basic realm="Zortex"'},
            )

        return f(*args, **kwargs)

    return decorated_function


class NotificationProcessor:
    """Process and schedule notifications"""

    def __init__(self):
        self.processing_lock = threading.Lock()

    def process_manifest(self, manifest):
        """Process notification manifest from Zortex"""
        user_id = manifest.get("user_id", "default")
        operation = manifest.get("operation", "sync")

        if operation == "sync":
            return self._sync_notifications(user_id, manifest.get("notifications", []))
        elif operation == "add":
            return self._add_notification(user_id, manifest.get("notification"))
        elif operation == "remove":
            return self._remove_notification(user_id, manifest.get("entry_id"))
        elif operation == "test":
            return self._test_notification(user_id, manifest.get("notification"))

        return False, "Unknown operation"

    def _sync_notifications(self, user_id, notifications):
        """Full sync - replace all notifications for user"""
        with sqlite3.connect(db.db_path) as conn:
            # Deactivate existing notifications
            conn.execute(
                "UPDATE notifications SET active = 0 WHERE user_id = ? AND active = 1",
                (user_id,),
            )

            # Add new notifications
            added = 0
            for notif in notifications:
                if self._add_notification_to_db(conn, user_id, notif):
                    added += 1

            conn.commit()
            return True, f"Synced {added} notifications"

    def _add_notification(self, user_id, notification):
        """Add a single notification"""
        with sqlite3.connect(db.db_path) as conn:
            success = self._add_notification_to_db(conn, user_id, notification)
            conn.commit()
            return success, "Notification added" if success else "Failed to add"

    def _add_notification_to_db(self, conn, user_id, notification):
        """Helper to add notification to database"""
        # Parse time information
        trigger_time = self._calculate_trigger_time(notification)
        if not trigger_time or trigger_time <= time.time():
            return False

        notif_id = (
            notification.get("id") or f"notif_{int(time.time())}_{secrets.token_hex(4)}"
        )

        conn.execute(
            """
            INSERT OR REPLACE INTO notifications 
            (id, user_id, entry_id, title, message, trigger_time, 
             repeat_pattern, repeat_interval, priority, tags, active)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
        """,
            (
                notif_id,
                user_id,
                notification.get("entry_id"),
                notification.get("title", ""),
                notification.get("message", ""),
                trigger_time,
                notification.get("repeat_pattern"),
                notification.get("repeat_interval"),
                notification.get("priority", "default"),
                json.dumps(notification.get("tags", [])),
            ),
        )

        return True

    def _calculate_trigger_time(self, notification):
        """Calculate when notification should trigger"""
        # Handle different time formats
        if "trigger_time" in notification:
            return notification["trigger_time"]

        if "date" in notification and "time" in notification:
            # Parse date and time
            date_str = notification["date"]
            time_str = notification.get("time", "09:00")
            notify_minutes = notification.get("notify_minutes", 15)

            try:
                dt = datetime.strptime(f"{date_str} {time_str}", "%Y-%m-%d %H:%M")
                dt = dt - timedelta(minutes=notify_minutes)
                return int(dt.timestamp())
            except:
                pass

        if "scheduled_time" in notification:
            return notification["scheduled_time"]

        return None

    def _remove_notification(self, user_id, entry_id):
        """Remove notification by entry_id"""
        with sqlite3.connect(db.db_path) as conn:
            conn.execute(
                "UPDATE notifications SET active = 0 WHERE user_id = ? AND entry_id = ?",
                (user_id, entry_id),
            )
            conn.commit()
            return True, "Notification removed"

    def _test_notification(self, user_id, notification):
        """Send test notification immediately"""
        self._send_notification(
            {
                "title": notification.get("title", "Test"),
                "message": notification.get("message", "Test notification"),
                "priority": notification.get("priority", "default"),
                "tags": notification.get("tags", ["test"]),
            }
        )
        return True, "Test sent"

    def check_and_send(self):
        """Check for due notifications and send them"""
        with self.processing_lock:
            now = int(time.time())

            with sqlite3.connect(db.db_path) as conn:
                # Get due notifications
                due = conn.execute(
                    """
                    SELECT * FROM notifications 
                    WHERE active = 1 AND trigger_time <= ?
                    ORDER BY trigger_time
                """,
                    (now,),
                ).fetchall()

                for row in due:
                    notif = self._row_to_dict(row)

                    # Send notification
                    if self._send_notification(notif):
                        # Update occurrence count
                        conn.execute(
                            "UPDATE notifications SET occurrence_count = occurrence_count + 1, last_sent = ? WHERE id = ?",
                            (now, notif["id"]),
                        )

                        # Handle repeat
                        if notif["repeat_pattern"]:
                            next_trigger = self._calculate_next_trigger(notif)
                            if next_trigger:
                                conn.execute(
                                    "UPDATE notifications SET trigger_time = ? WHERE id = ?",
                                    (next_trigger, notif["id"]),
                                )
                            else:
                                # No more occurrences
                                conn.execute(
                                    "UPDATE notifications SET active = 0 WHERE id = ?",
                                    (notif["id"],),
                                )
                        else:
                            # One-time notification
                            conn.execute(
                                "UPDATE notifications SET active = 0 WHERE id = ?",
                                (notif["id"],),
                            )

                conn.commit()

    def _calculate_next_trigger(self, notification):
        """Calculate next trigger time for repeating notification"""
        pattern = notification["repeat_pattern"]
        current = notification["trigger_time"]

        if pattern == "daily":
            return current + 86400
        elif pattern == "weekly":
            return current + (7 * 86400)
        elif pattern == "monthly":
            # Add roughly a month
            dt = datetime.fromtimestamp(current)
            if dt.month == 12:
                dt = dt.replace(year=dt.year + 1, month=1)
            else:
                dt = dt.replace(month=dt.month + 1)
            return int(dt.timestamp())
        elif pattern and "d" in pattern:
            # Parse "3d" format
            days = int(pattern.replace("d", ""))
            return current + (days * 86400)

        return None

    def _send_notification(self, notif):
        """Send notification via ntfy"""
        try:
            headers = {
                "Title": notif["title"],
                "Priority": notif.get("priority", "default"),
            }

            tags = notif.get("tags")
            if tags:
                if isinstance(tags, str):
                    tags = json.loads(tags)
                headers["Tags"] = ",".join(tags)

            response = requests.post(
                f"{CONFIG['ntfy_url']}/{CONFIG['ntfy_topic']}",
                data=notif["message"].encode("utf-8"),
                headers=headers,
                timeout=10,
            )

            return response.status_code == 200
        except Exception as e:
            app.logger.error(f"Failed to send notification: {e}")
            return False

    def _row_to_dict(self, row):
        """Convert database row to dictionary"""
        cols = [
            "id",
            "user_id",
            "entry_id",
            "title",
            "message",
            "trigger_time",
            "repeat_pattern",
            "repeat_interval",
            "last_sent",
            "occurrence_count",
            "active",
            "priority",
            "tags",
            "created_at",
            "updated_at",
        ]
        return dict(zip(cols, row))


processor = NotificationProcessor()


# Background scheduler
def run_scheduler():
    """Background thread for checking notifications"""
    while True:
        try:
            processor.check_and_send()
        except Exception as e:
            app.logger.error(f"Scheduler error: {e}")
        time.sleep(CONFIG["check_interval"])


# Flask Routes


@app.route("/")
@require_auth
def index():
    """Redirect to today's digest"""
    today = datetime.now().strftime("%Y-%m-%d")
    return app.redirect(f"/digest/{today}")


@app.route("/digest/<date>")
@require_auth
def show_digest(date):
    """Display digest for a specific date"""
    with sqlite3.connect(db.db_path) as conn:
        result = conn.execute(
            "SELECT data FROM digests WHERE date = ?", (date,)
        ).fetchone()

        if result:
            digest_data = json.loads(result[0])
        else:
            digest_data = {
                "date": date,
                "formatted_date": datetime.strptime(date, "%Y-%m-%d").strftime(
                    "%B %d, %Y"
                ),
                "sections": [],
            }

    return render_template_string(DIGEST_TEMPLATE, **digest_data)


@app.route("/api/manifest", methods=["POST"])
@require_auth
def receive_manifest():
    """API endpoint to receive notification manifest"""
    try:
        manifest = request.json
        success, message = processor.process_manifest(manifest)

        return jsonify(
            {"success": success, "message": message, "timestamp": int(time.time())}
        )
    except Exception as e:
        app.logger.error(f"Error processing manifest: {e}")
        return jsonify({"success": False, "error": str(e)}), 500


@app.route("/api/digest", methods=["POST"])
@require_auth
def receive_digest():
    """API endpoint to receive digest from Zortex"""
    try:
        data = request.json
        date = data.get("date", datetime.now().strftime("%Y-%m-%d"))

        with sqlite3.connect(db.db_path) as conn:
            conn.execute(
                """
                INSERT OR REPLACE INTO digests (date, data, updated_at)
                VALUES (?, ?, CURRENT_TIMESTAMP)
            """,
                (date, json.dumps(data)),
            )

        # Send email if configured
        if CONFIG["email_enabled"] and data.get("send_email"):
            # Email sending code would go here
            pass

        return jsonify({"success": True, "date": date})
    except Exception as e:
        app.logger.error(f"Error receiving digest: {e}")
        return jsonify({"success": False, "error": str(e)}), 500


@app.route("/api/notifications", methods=["GET"])
@require_auth
def list_notifications():
    """List active notifications"""
    with sqlite3.connect(db.db_path) as conn:
        notifications = conn.execute("""
            SELECT id, title, trigger_time, repeat_pattern, occurrence_count
            FROM notifications
            WHERE active = 1
            ORDER BY trigger_time
            LIMIT 100
        """).fetchall()

        return jsonify(
            {
                "notifications": [
                    {
                        "id": n[0],
                        "title": n[1],
                        "trigger_time": n[2],
                        "trigger_date": datetime.fromtimestamp(n[2]).isoformat(),
                        "repeat_pattern": n[3],
                        "occurrence_count": n[4],
                    }
                    for n in notifications
                ]
            }
        )


@app.route("/api/status")
def status():
    """Health check endpoint (no auth required)"""
    with sqlite3.connect(db.db_path) as conn:
        active_count = conn.execute(
            "SELECT COUNT(*) FROM notifications WHERE active = 1"
        ).fetchone()[0]

        recent_digests = conn.execute(
            "SELECT date FROM digests ORDER BY date DESC LIMIT 7"
        ).fetchall()

    return jsonify(
        {
            "status": "healthy",
            "active_notifications": active_count,
            "recent_digests": [d[0] for d in recent_digests],
            "ntfy_configured": bool(CONFIG["ntfy_url"]),
        }
    )


if __name__ == "__main__":
    # Start background scheduler
    scheduler_thread = threading.Thread(target=run_scheduler, daemon=True)
    scheduler_thread.start()

    # Run Flask app
    app.run(host="0.0.0.0", port=CONFIG["port"], debug=False)
