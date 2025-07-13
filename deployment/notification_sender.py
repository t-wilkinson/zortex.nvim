# notification_sender.py
import json
import boto3
import requests
from datetime import datetime, timedelta

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

    response = requests.post(
        f"https://ntfy.sh/{topic}", data=message.encode("utf-8"), headers=headers
    )

    return response.status_code == 200


def handler(event, context):
    """Send scheduled notification"""
    notification_id = event["notification_id"]

    # Get notification details
    response = table.get_item(Key={"id": notification_id})
    if "Item" not in response:
        return {"statusCode": 404}

    notification = response["Item"]

    # Send notification
    success = send_ntfy(
        notification["ntfy_topic"],
        notification["title"],
        notification["message"],
        notification["ntfy_priority"],
        notification.get("ntfy_tags", []),
    )

    if success:
        # Update last sent
        table.update_item(
            Key={"id": notification_id},
            UpdateExpression="SET last_sent = :ls, occurrence_count = occurrence_count + :inc",
            ExpressionAttributeValues={":ls": datetime.now().isoformat(), ":inc": 1},
        )

        # Schedule next occurrence if repeating
        if notification.get("repeat_pattern"):
            # Recalculate next trigger
            next_trigger = calculate_next_trigger(notification)

            if next_trigger:
                # Create new EventBridge rule
                rule_arn = create_eventbridge_rule(notification_id, next_trigger)

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
                table.update_item(
                    Key={"id": notification_id},
                    UpdateExpression="SET status = :status",
                    ExpressionAttributeValues={":status": "completed"},
                )
        else:
            # One-time notification, mark as completed
            table.update_item(
                Key={"id": notification_id},
                UpdateExpression="SET status = :status",
                ExpressionAttributeValues={":status": "completed"},
            )

        # Delete the current EventBridge rule
        events.delete_rule(Name=f"zortex-notify-{notification_id}")

    return {"statusCode": 200, "body": json.dumps({"success": success})}


# Reuse calculate_next_trigger and create_eventbridge_rule from above
