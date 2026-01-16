#!/bin/bash
# deployment/entrypoint.sh

# Pass environment variables to cron
printenv | grep -E '^(NTFY_SERVER_URL|NTFY_TOPIC|NTFY_AUTH_TOKEN|TZ)=' >/etc/environment

# Start the cron daemon in the background
cron

echo "Cron daemon started."
echo "Starting Flask server..."

# Run the Flask server as the main process
exec python server.py
