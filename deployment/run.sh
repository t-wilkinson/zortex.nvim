#!/bin/bash
# deployment/run.sh

. /etc/environment

# Load environment variables
NTFY_SERVER_URL=${NTFY_SERVER_URL:-"http://localhost:5000"}
NTFY_TOPIC=${NTFY_TOPIC:-"zortex-notify"}
NTFY_AUTH_TOKEN=${NTFY_AUTH_TOKEN:-""}
DATABASE_PATH="/app/data/notifications.db"

# Log file
LOG_FILE="/var/log/zortex-notifications.log"

# Function to log messages
log_message() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >>$LOG_FILE
}

# Function to send notification via ntfy
send_ntfy_notification() {
  local title="$1"
  local message="$2"
  local priority="$3"
  local tags="$4"

  # Build curl command
  local curl_cmd="curl -s"

  # Add authentication if provided
  if [ -n "$NTFY_AUTH_TOKEN" ]; then
    curl_cmd="$curl_cmd -H \"Authorization: Bearer $NTFY_AUTH_TOKEN\""
  fi

  # Add headers
  curl_cmd="$curl_cmd -H \"Title: $title\""
  curl_cmd="$curl_cmd -H \"Priority: $priority\""

  if [ -n "$tags" ]; then
    curl_cmd="$curl_cmd -H \"Tags: $tags\""
  fi

  # Add message and URL
  curl_cmd="$curl_cmd -d \"$message\" \"${NTFY_SERVER_URL}/${NTFY_TOPIC}\""

  # Execute curl command
  eval $curl_cmd
  return $?
}

# Get current timestamp
CURRENT_TIME=$(date +%s)

# Process pending notifications
(
  sqlite3 $DATABASE_PATH <<EOF
SELECT id, title, message, priority, 
       CASE 
           WHEN tags IS NOT NULL AND tags != '[]' 
           THEN REPLACE(REPLACE(REPLACE(tags, '["', ''), '"]', ''), '","', ',')
           ELSE ''
       END as tags
FROM notifications 
WHERE sent_at IS NULL 
  AND scheduled_time <= $CURRENT_TIME
ORDER BY scheduled_time;
EOF
) | while IFS='|' read -r id title message priority tags; do
  # Send notification
  if send_ntfy_notification "$title" "$message" "$priority" "$tags"; then
    # Mark as sent
    sqlite3 $DATABASE_PATH "UPDATE notifications SET sent_at = $CURRENT_TIME WHERE id = $id"
    log_message "Sent notification $id: $title"
  else
    log_message "Failed to send notification $id: $title"
  fi
done

# Clean up old sent notifications (older than 7 days)
CLEANUP_TIME=$((CURRENT_TIME - 604800)) # 7 days in seconds
DELETED=$(sqlite3 $DATABASE_PATH "DELETE FROM notifications WHERE sent_at IS NOT NULL AND sent_at < $CLEANUP_TIME; SELECT changes();")

if [ "$DELETED" -gt 0 ]; then
  log_message "Cleaned up $DELETED old notifications"
fi

# Clean up stale unsent notifications (older than 30 days)
STALE_TIME=$((CURRENT_TIME - 2592000)) # 30 days in seconds
STALE_DELETED=$(sqlite3 $DATABASE_PATH "DELETE FROM notifications WHERE sent_at IS NULL AND scheduled_time < $STALE_TIME; SELECT changes();")

if [ "$STALE_DELETED" -gt 0 ]; then
  log_message "Removed $STALE_DELETED stale unsent notifications"
fi
