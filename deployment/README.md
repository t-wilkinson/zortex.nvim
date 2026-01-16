# Zortex Notification Server

A Docker container that receives notification manifests from the Zortex note system and sends them to an ntfy server at scheduled times.

## Features

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
