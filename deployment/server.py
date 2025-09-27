#!/usr/bin/env python3
import os
import sqlite3
import json
import logging
from datetime import datetime, timezone
from flask import Flask, request, jsonify
from contextlib import contextmanager

app = Flask(__name__)

# Configuration
DATABASE_PATH = os.environ.get("DATABSE_PATH", "/app/data/notifications.db")
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO")
FLASK_PORT = int(os.environ.get("FLASK_PORT", 5000))

# Setup logging
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL),
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)


@contextmanager
def get_db():
    """Context manager for database connections"""
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
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_user ON notifications(user_id)")
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_sent ON notifications(sent_at)")


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
    """Sync a batch of notifications, replacing existing pending ones"""
    try:
        with get_db() as conn:
            cursor = conn.cursor()

            # Clear existing pending notifications for this user
            cursor.execute(
                """
                DELETE FROM notifications 
                WHERE user_id = ? AND sent_at IS NULL
            """,
                (user_id,),
            )

            # Insert new notifications
            added = 0
            skipped = 0

            for notif in notifications:
                try:
                    # Generate deduplication key if not provided
                    dedup_key = notif.get("deduplication_key")
                    if not dedup_key and notif.get("entry_id"):
                        # Create dedup key from entry_id and scheduled_time
                        dedup_key = (
                            f"{notif['entry_id']}_{notif.get('scheduled_time', 0)}"
                        )

                    cursor.execute(
                        """
                        INSERT INTO notifications 
                        (user_id, entry_id, title, message, scheduled_time, 
                         priority, tags, created_at, deduplication_key)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                        (
                            user_id,
                            notif.get("entry_id"),
                            notif.get("title", "Zortex Notification"),
                            notif.get("message", ""),
                            notif.get(
                                "scheduled_time",
                                int(datetime.now(timezone.utc).timestamp()),
                            ),
                            notif.get("priority", "default"),
                            json.dumps(notif.get("tags", [])),
                            int(datetime.now(timezone.utc).timestamp()),
                            dedup_key,
                        ),
                    )
                    added += 1
                except sqlite3.IntegrityError:
                    # Duplicate notification (based on deduplication_key)
                    skipped += 1
                    logger.debug(f"Skipped duplicate notification: {dedup_key}")
                except Exception as e:
                    logger.error(f"Error adding notification: {e}")
                    skipped += 1

            logger.info(
                f"Synced notifications for {user_id}: {added} added, {skipped} skipped"
            )
            return {
                "success": True,
                "added": added,
                "skipped": skipped,
                "total": len(notifications),
            }

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


if __name__ == "__main__":
    init_database()
    logger.info(f"Starting Zortex notification server on port {FLASK_PORT}")
    app.run(host="0.0.0.0", port=FLASK_PORT, debug=(LOG_LEVEL == "DEBUG"))
