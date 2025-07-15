# notification_sender/handler.py
import json
import boto3
from datetime import datetime, timedelta

import os, sys, pathlib

# add vendor to path
root = pathlib.Path(__file__).parent
sys.path.insert(0, str(root / "vendor"))

import requests
from dateutil import parser as date_parser
from dateutil.rrule import rrule, DAILY, WEEKLY, MONTHLY

dynamodb = boto3.resource("dynamodb")
events = boto3.client("events")
table = dynamodb.Table("zortex-notifications")


def send_ntfy(topic, title, message, priority="default", tags=None):
    """Send notification via ntfy"""
    headers = {
        "Title": title,
        "Priority": priority,
    }

    if tags:
        headers["Tags"] = ",".join(tags)

    try:
        response = requests.post(
            f"https://ntfy.sh/{topic}", data=message.encode("utf-8"), headers=headers
        )
        response.raise_for_status()  # Raise an exception for bad status codes
        return True
    except requests.exceptions.RequestException as e:
        print(f"Error sending ntfy notification: {e}")
        return False


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
        # We check if the notification time is in the future.
        # This function is called *after* a notification has fired,
        # so we need to find the *next* one.
        return None

    # Calculate next occurrence based on repeat pattern
    freq, interval = parse_repeat_pattern(notification.get("repeat_pattern"))
    if not freq:
        return None

    # Use rrule to find next occurrence AFTER the one that just fired
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


def create_eventbridge_rule(notification_id, trigger_time, function_arn):
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
                "Arn": function_arn,
                "Input": json.dumps({"notification_id": notification_id}),
            }
        ],
    )

    return response["RuleArn"]


def handler(event, context):
    """Send scheduled notification"""
    notification_id = event["notification_id"]

    # Get notification details
    response = table.get_item(Key={"id": notification_id})
    if "Item" not in response:
        print(f"Notification with ID {notification_id} not found.")
        return {"statusCode": 404}

    notification = response["Item"]

    # Send notification
    print(f"Sending notification for: {notification['title']}")
    success = send_ntfy(
        notification["ntfy_topic"],
        notification["title"],
        notification["message"],
        notification["ntfy_priority"],
        notification.get("ntfy_tags", []),
    )

    if success:
        print("Notification sent successfully.")
        # Update last sent and occurrence count
        # Initialize occurrence_count if it doesn't exist
        current_count = notification.get("occurrence_count", 0)
        table.update_item(
            Key={"id": notification_id},
            UpdateExpression="SET last_sent = :ls, occurrence_count = :oc",
            ExpressionAttributeValues={
                ":ls": datetime.now().isoformat(),
                ":oc": current_count + 1,
            },
        )

        # Delete the current EventBridge rule that just fired
        try:
            rule_name = f"zortex-notify-{notification_id}"
            # We need to remove targets before deleting the rule
            events.remove_targets(Rule=rule_name, Ids=["1"])
            events.delete_rule(Name=rule_name)
            print(f"Deleted rule: {rule_name}")
        except events.exceptions.ResourceNotFoundException:
            print(f"Rule for {notification_id} already deleted.")
        except Exception as e:
            print(f"Error deleting rule for {notification_id}: {e}")

        # Schedule next occurrence if repeating
        if notification.get("repeat_pattern"):
            print("Repeating notification, calculating next trigger.")
            # Recalculate next trigger
            next_trigger = calculate_next_trigger(notification)

            if next_trigger:
                print(f"Next trigger is at {next_trigger.isoformat()}")
                # Create new EventBridge rule, passing the function's own ARN from the context
                rule_arn = create_eventbridge_rule(
                    notification_id, next_trigger, context.invoked_function_arn
                )

                table.update_item(
                    Key={"id": notification_id},
                    UpdateExpression="SET next_trigger = :nt, schedule_rule_arn = :arn",
                    ExpressionAttributeValues={
                        ":nt": next_trigger.isoformat(),
                        ":arn": rule_arn,
                    },
                )
            else:
                # No more occurrences
                print("No more occurrences, marking as completed.")
                table.update_item(
                    Key={"id": notification_id},
                    UpdateExpression="SET #s = :status",
                    ExpressionAttributeNames={"#s": "status"},
                    ExpressionAttributeValues={":status": "completed"},
                )
        else:
            # One-time notification, mark as completed
            print("One-time notification, marking as completed.")
            table.update_item(
                Key={"id": notification_id},
                UpdateExpression="SET #s = :status",
                ExpressionAttributeNames={"#s": "status"},
                ExpressionAttributeValues={":status": "completed"},
            )

    else:
        print("Failed to send notification.")

    return {"statusCode": 200, "body": json.dumps({"success": success})}
