FROM python:3.11-slim

# Install cron and curl
RUN apt-get update && apt-get install -y \
  cron \
  curl \
  sqlite3 \
  && rm -rf /var/lib/apt/lists/*;

# Set working directory
WORKDIR /app

# Copy requirements and install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application files
COPY server.py .
COPY run.sh .
COPY crontab /etc/cron.d/notification-cron

# Make scripts executable
RUN chmod +x run.sh
RUN chmod 0644 /etc/cron.d/notification-cron;

# Create log file
RUN touch /var/log/cron.log;

# Environment variables (with defaults)
ENV NTFY_SERVER_URL=http://ntfy.sh
ENV NTFY_TOPIC=zortex-notify
ENV NTFY_AUTH_TOKEN=""
ENV FLASK_PORT=5000
ENV TZ=UTC
ENV DATABASE_PATH=/app/data/notifications.db

# Expose Flask port
EXPOSE 5000

# Start cron and Flask
CMD cron && python server.py
