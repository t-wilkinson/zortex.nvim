# manifest_processor/handler.py
import json
import boto3
import uuid
import os
from datetime import datetime, timedelta
from dateutil import parser as date_parser
from dateutil.rrule import rrule, DAILY, WEEKLY, MONTHLY

dynamodb = boto3.resource("dynamodb")
events = boto3.client("events")
table = dynamodb.Table("zortex-notifications")


def parse_repeat_pattern(pattern):
    """Convert zortex repeat patterns to rrule"""
    if pattern == "daily":
        return DAILY, 1
    elif pattern == "weekly":
        return WEEKLY, 1
    elif pattern == "monthly":
        return MONTHLY, 1
    elif pattern and pattern.endswith("d"):
        days = int(pattern[:-1])
        return DAILY, days
    elif pattern and pattern.endswith("w"):
        weeks = int(pattern[:-1])
        return WEEKLY, weeks
    return None, None


def calculate_next_trigger(notification):
    """Calculate next notification time based on repeat pattern"""
    base_datetime = datetime.fromisoformat(
        f"{notification['date']}T{notification['time']}:00"
    )
    notify_delta = timedelta(minutes=notification.get("notify_minutes", 15))

    # Check date range
    if "from_date" in notification and notification["from_date"]:
        from_date = date_parser.parse(notification["from_date"]).date()
        if base_datetime.date() < from_date:
            base_datetime = datetime.combine(from_date, base_datetime.time())

    if "to_date" in notification and notification["to_date"]:
        to_date = date_parser.parse(notification["to_date"]).date()
        if base_datetime.date() > to_date:
            return None  # Outside date range

    # Calculate notification time
    notify_time = base_datetime - notify_delta

    # If no repeat, return single occurrence
    if not notification.get("repeat_pattern"):
        return notify_time if notify_time > datetime.now() else None

    # Calculate next occurrence based on repeat pattern
    freq, interval = parse_repeat_pattern(notification.get("repeat_pattern"))
    if not freq:
        return notify_time if notify_time > datetime.now() else None

    # Use rrule to find next occurrence
    rule = rrule(freq, interval=interval, dtstart=base_datetime)
    now = datetime.now()

    for occurrence in rule:
        notify_time = occurrence - notify_delta
        if notify_time > now:
            # Check if within date range
            if "to_date" in notification and notification["to_date"]:
                if (
                    occurrence.date()
                    > date_parser.parse(notification["to_date"]).date()
                ):
                    return None
            return notify_time

    return None


def create_eventbridge_rule(notification_id, trigger_time):
    """Create one-time EventBridge rule for notification"""
    rule_name = f"zortex-notify-{notification_id}"

    # Create cron expression for one-time execution
    cron = f"cron({trigger_time.minute} {trigger_time.hour} {trigger_time.day} {trigger_time.month} ? {trigger_time.year})"

    # Create or update rule
    response = events.put_rule(
        Name=rule_name,
        ScheduleExpression=cron,
        State="ENABLED",
        Description=f"Zortex notification trigger for {notification_id}",
    )

    # Add Lambda target
    events.put_targets(
        Rule=rule_name,
        Targets=[
            {
                "Id": "1",
                "Arn": os.environ["NOTIFICATION_SENDER_ARN"],
                "Input": json.dumps({"notification_id": notification_id}),
            }
        ],
    )

    return response["RuleArn"]


def handler(event, context):
    """Process notification manifest from Zortex"""
    body = json.loads(event["body"])
    user_id = body["user_id"]
    operation = body["operation"]  # add|update|remove|sync

    if operation == "sync":
        # Full sync - replace all notifications
        notifications = body["notifications"]

        # Mark existing as inactive
        # FIX: Added ExpressionAttributeNames to handle reserved keyword 'status'
        response = table.query(
            IndexName="user-status-index",
            KeyConditionExpression="user_id = :uid AND #s = :status",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":uid": user_id, ":status": "active"},
        )

        for item in response["Items"]:
            # Cancel EventBridge rule
            if "schedule_rule_arn" in item:
                try:
                    events.delete_rule(Name=f"zortex-notify-{item['id']}")
                except events.exceptions.ResourceNotFoundException:
                    print(
                        f"Rule zortex-notify-{item['id']} not found, skipping delete."
                    )

            # Mark as completed
            # FIX: Added ExpressionAttributeNames to handle reserved keyword 'status'
            table.update_item(
                Key={"id": item["id"]},
                UpdateExpression="SET #s = :status",
                ExpressionAttributeNames={"#s": "status"},
                ExpressionAttributeValues={":status": "completed"},
            )

        # Add new notifications
        for notif in notifications:
            process_notification(user_id, notif)

    elif operation == "add":
        notification = body["notification"]
        process_notification(user_id, notification)

    elif operation == "update":
        notification = body["notification"]
        entry_id = notification["entry_id"]

        # Find existing by entry_id
        response = table.query(
            IndexName="user-entry-index",
            KeyConditionExpression="user_id = :uid AND entry_id = :eid",
            ExpressionAttributeValues={":uid": user_id, ":eid": entry_id},
        )

        if response["Items"]:
            # Cancel old rule
            old_item = response["Items"][0]
            if "schedule_rule_arn" in old_item:
                try:
                    events.delete_rule(Name=f"zortex-notify-{old_item['id']}")
                except events.exceptions.ResourceNotFoundException:
                    print(
                        f"Rule zortex-notify-{old_item['id']} not found, skipping delete."
                    )

            # Update with new data
            process_notification(user_id, notification, notification_id=old_item["id"])

    elif operation == "remove":
        entry_id = body["entry_id"]

        # Find and deactivate
        response = table.query(
            IndexName="user-entry-index",
            KeyConditionExpression="user_id = :uid AND entry_id = :eid",
            ExpressionAttributeValues={":uid": user_id, ":eid": entry_id},
        )

        for item in response["Items"]:
            if "schedule_rule_arn" in item:
                try:
                    events.delete_rule(Name=f"zortex-notify-{item['id']}")
                except events.exceptions.ResourceNotFoundException:
                    print(
                        f"Rule zortex-notify-{item['id']} not found, skipping delete."
                    )

            # Mark as completed
            # FIX: Added ExpressionAttributeNames to handle reserved keyword 'status'
            table.update_item(
                Key={"id": item["id"]},
                UpdateExpression="SET #s = :status",
                ExpressionAttributeNames={"#s": "status"},
                ExpressionAttributeValues={":status": "completed"},
            )

    return {"statusCode": 200, "body": json.dumps({"success": True})}


def process_notification(user_id, notification, notification_id=None):
    """Process a single notification"""
    if not notification_id:
        notification_id = str(uuid.uuid4())

    # Calculate next trigger
    next_trigger = calculate_next_trigger(notification)
    if not next_trigger:
        print(
            f"No future trigger for notification {notification.get('entry_id')}. Skipping."
        )
        return  # No future triggers

    # Create EventBridge rule
    rule_arn = create_eventbridge_rule(notification_id, next_trigger)

    # Save to DynamoDB
    item = {
        "id": notification_id,
        "user_id": user_id,
        "entry_id": notification.get("entry_id"),
        "status": "active",
        "created_at": datetime.now().isoformat(),
        "updated_at": datetime.now().isoformat(),
        "title": notification.get("title", ""),
        "message": notification.get("message", ""),
        "date": notification["date"],
        "time": notification.get("time", "09:00"),
        "from_date": notification.get("from_date"),
        "to_date": notification.get("to_date"),
        "notify_minutes": notification.get("notify_minutes", 15),
        "repeat_pattern": notification.get("repeat_pattern"),
        "repeat_interval": notification.get("repeat_interval"),
        "next_trigger": next_trigger.isoformat(),
        "schedule_rule_arn": rule_arn,
        "ntfy_topic": notification.get("ntfy_topic", f"zortex-{user_id}"),
        "ntfy_priority": notification.get("priority", "default"),
        "ntfy_tags": notification.get("tags", ["calendar"]),
    }

    table.put_item(Item=item)
