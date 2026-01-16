#!/bin/bash
# deployment/test_notification.sh

# Test script for Zortex notification server
# This script helps test the complete notification flow

SERVER_URL="${1:-http://127.0.0.1:5000}"
USER_ID="${2:-test-user}"

echo "🧪 Testing Zortex Notification Server"
echo "======================================"
echo "Server: $SERVER_URL"
echo "User: $USER_ID"
echo ""

# Function to print colored output
print_result() {
  if [ "$1" -eq 0 ]; then
    echo "✅ $2"
  else
    echo "❌ $2"
  fi
}

# 1. Test server health
echo "1️⃣  Testing server health..."
HEALTH_RESPONSE=$(curl -s "$SERVER_URL/health")
if echo "$HEALTH_RESPONSE" | grep -q "healthy"; then
  print_result 0 "Server is healthy"
else
  print_result 1 "Server health check failed"
  echo "Response: $HEALTH_RESPONSE"
  exit 1
fi
echo ""

# 2. Test immediate notification
echo "2️⃣  Testing immediate notification (no delay)..."
IMMEDIATE_RESPONSE=$(curl -s -X POST "$SERVER_URL/test" \
  -H "Content-Type: application/json" \
  -d "{
        \"user_id\": \"$USER_ID\",
        \"title\": \"Test: Immediate Notification\",
        \"message\": \"This should appear immediately in ntfy\",
        \"delay\": 0
    }")

if echo "$IMMEDIATE_RESPONSE" | grep -q "\"overall_status\":\"SUCCESS\""; then
  print_result 0 "Immediate notification sent successfully"
  echo "   📱 Check your ntfy app now!"
else
  print_result 1 "Immediate notification failed"
  echo "Response: $IMMEDIATE_RESPONSE" | jq '.' 2>/dev/null || echo "$IMMEDIATE_RESPONSE"
fi
echo ""

# 3. Test delayed notification
echo "3️⃣  Testing delayed notification (5 seconds)..."
DELAYED_RESPONSE=$(curl -s -X POST "$SERVER_URL/test" \
  -H "Content-Type: application/json" \
  -d "{
        \"user_id\": \"$USER_ID\",
        \"title\": \"Test: Delayed Notification\",
        \"message\": \"This should appear in 5 seconds\",
        \"delay\": 5
    }")

if echo "$DELAYED_RESPONSE" | grep -q "\"database_insert\":\"success\""; then
  print_result 0 "Delayed notification scheduled"
  echo "   ⏰ Wait 5 seconds for it to appear in ntfy..."

  # Wait and check if it gets sent
  sleep 6
  echo "   Checking if delayed notification was sent..."

  # The test endpoint already checks if it was sent, but we can verify
  PENDING=$(curl -s "$SERVER_URL/pending?user_id=$USER_ID")
  PENDING_COUNT=$(echo "$PENDING" | jq '.count' 2>/dev/null || echo "unknown")
  echo "   📊 Pending notifications for $USER_ID: $PENDING_COUNT"
else
  print_result 1 "Failed to schedule delayed notification"
  echo "Response: $DELAYED_RESPONSE" | jq '.' 2>/dev/null || echo "$DELAYED_RESPONSE"
fi
echo ""

# 4. Test GET method (easy browser test)
echo "4️⃣  Testing GET method (for browser testing)..."
GET_URL="$SERVER_URL/test?user_id=$USER_ID&title=Browser%20Test&message=Testing%20from%20curl"
echo "   URL: $GET_URL"
GET_RESPONSE=$(curl -s "$GET_URL")

if echo "$GET_RESPONSE" | grep -q "\"success\":true"; then
  print_result 0 "GET method works"
  echo "   💡 You can test from browser: $GET_URL"
else
  print_result 1 "GET method failed"
fi
echo ""

# 5. Check pending notifications
echo "5️⃣  Checking all pending notifications..."
PENDING_RESPONSE=$(curl -s "$SERVER_URL/pending?user_id=$USER_ID")
PENDING_COUNT=$(echo "$PENDING_RESPONSE" | jq '.count' 2>/dev/null || echo "0")

if [ "$PENDING_COUNT" != "0" ] && [ "$PENDING_COUNT" != "null" ]; then
  echo "   ⚠️  Found $PENDING_COUNT pending notifications"
  echo "$PENDING_RESPONSE" | jq '.notifications[] | {title: .title, scheduled: .scheduled_datetime}' 2>/dev/null
else
  echo "   ✨ No pending notifications (all sent)"
fi
echo ""

# Summary
echo "======================================"
echo "📋 Test Summary:"
echo ""
echo "If all tests passed, you should see notifications in your ntfy app."
echo "Make sure:"
echo "  1. Your ntfy app is subscribed to the correct topic"
echo "  2. The NTFY_SERVER_URL and NTFY_TOPIC env vars are correct"
echo "  3. The Docker container has internet access"
echo ""
echo "To view Docker logs:"
echo "  docker logs zortex-notifications"
echo ""
echo "To manually trigger notification processing:"
echo "  docker exec zortex-notifications /app/run.sh"
echo "======================================"
