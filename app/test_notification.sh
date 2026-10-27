#!/usr/bin/env bash
# app/test_notification.sh [SERVER_URL] [USER_ID]: exercise the notification API of `zortex serve`
set -u
SERVER_URL="${1:-http://127.0.0.1:8090}"
USER_ID="${2:-test-user}"
KEY=()
[ -n "${ZORTEX_API_KEY:-}" ] && KEY=(-H "X-API-Key: $ZORTEX_API_KEY")

echo "health:   $(curl -s "$SERVER_URL/healthz")"
echo "ntfy:     $(curl -s -X POST "${KEY[@]}" -H 'Content-Type: application/json' -d '{"title":"Zortex test","message":"ntfy works"}' "$SERVER_URL/api/notifications/test")"
AT=$(($(date +%s) + 30))
echo "schedule: $(curl -s -X POST "${KEY[@]}" -H 'Content-Type: application/json' \
  -d "{\"user_id\":\"$USER_ID\",\"notification\":{\"title\":\"Zortex: in 30 s\",\"message\":\"scheduled test\",\"scheduled_time\":$AT,\"deduplication_key\":\"test_$AT\"}}" \
  "$SERVER_URL/api/notifications")"
echo "pending:  $(curl -s "${KEY[@]}" "$SERVER_URL/api/notifications?user_id=$USER_ID")"
echo "The scheduled one arrives within ~30-50 s."
