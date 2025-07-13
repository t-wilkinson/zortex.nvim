# main.tf
provider "aws" {
  region = "us-east-1"
}

data "archive_file" "manifest_processor" {
  type        = "zip"
  source_dir  = "${path.module}/manifest_processor" # handler.py + libs
  output_path = "${path.module}/manifest_processor.zip"
}

data "archive_file" "notification_sender" {
  type        = "zip"
  source_file = "${path.module}/notification_sender.py"
  output_path = "${path.module}/notification_sender.zip"
}

# DynamoDB Table
resource "aws_dynamodb_table" "notifications" {
  name         = "zortex-notifications"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  attribute {
    name = "user_id"
    type = "S"
  }

  attribute {
    name = "status"
    type = "S"
  }

  attribute {
    name = "entry_id"
    type = "S"
  }

  global_secondary_index {
    name            = "user-status-index"
    hash_key        = "user_id"
    range_key       = "status"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "user-entry-index"
    hash_key        = "user_id"
    range_key       = "entry_id"
    projection_type = "ALL"
  }
}

# Lambda Functions
resource "aws_lambda_function" "manifest_processor" {
  function_name    = "zortex-manifest-processor"
  filename         = data.archive_file.manifest_processor.output_path
  source_code_hash = data.archive_file.manifest_processor.output_base64sha256
  role             = aws_iam_role.lambda_role.arn
  handler          = "handler.handler"
  runtime          = "python3.9"
  timeout          = 60

  environment {
    variables = {
      NOTIFICATION_SENDER_ARN = aws_lambda_function.notification_sender.arn
    }
  }
}

resource "aws_lambda_function" "notification_sender" {
  function_name    = "zortex-notification-sender"
  filename         = data.archive_file.manifest_processor.output_path
  source_code_hash = data.archive_file.manifest_processor.output_base64sha256
  role             = aws_iam_role.lambda_role.arn
  handler          = "notification_sender.handler"
  runtime          = "python3.9"
  timeout          = 30
}

# API Gateway
resource "aws_apigatewayv2_api" "main" {
  name          = "zortex-notifications-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id           = aws_apigatewayv2_api.main.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.manifest_processor.invoke_arn
}

resource "aws_apigatewayv2_route" "main" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "POST /manifest"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "main" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "prod"
  auto_deploy = true
}

# IAM Role for Lambda
resource "aws_iam_role" "lambda_role" {
  name = "zortex-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

# IAM Policies
resource "aws_iam_role_policy" "lambda_policy" {
  name = "zortex-lambda-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query",
          "dynamodb:Scan"
        ]
        Resource = [
          aws_dynamodb_table.notifications.arn,
          "${aws_dynamodb_table.notifications.arn}/index/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "events:PutRule",
          "events:DeleteRule",
          "events:PutTargets",
          "events:RemoveTargets"
        ]
        Resource = "arn:aws:events:us-east-1:229817327380:rule/zortex-notify-*"
      },
      {
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction"
        ]
        Resource = aws_lambda_function.notification_sender.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# Lambda Permissions
resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.manifest_processor.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.notification_sender.function_name
  principal     = "events.amazonaws.com"
  source_arn    = "arn:aws:events:us-east-1:229817327380:rule/zortex-notify-*"
}

# Output API endpoint
output "api_endpoint" {
  value = "${aws_apigatewayv2_stage.main.invoke_url}/manifest"
}
