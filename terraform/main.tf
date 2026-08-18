data "aws_caller_identity" "current" {}

locals {
  function_name       = "govee-sunset-scene"
  lambda_role_name    = "govee-scene-lambda-role"
  scheduler_role_name = "govee-scene-scheduler-role"
  plan_schedule_name  = "govee-plan-tonight"
}

# ---------------------------------------------------------------------------
# IAM role EventBridge Scheduler assumes to invoke the Lambda
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "scheduler_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = local.scheduler_role_name
  assume_role_policy = data.aws_iam_policy_document.scheduler_trust.json
}

data "aws_iam_policy_document" "scheduler_permissions" {
  statement {
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.govee_sunset_scene.arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "invoke-govee-lambda"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler_permissions.json
}

# ---------------------------------------------------------------------------
# IAM role the Lambda itself runs as
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "lambda_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = local.lambda_role_name
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

data "aws_iam_policy_document" "lambda_permissions" {
  statement {
    sid       = "Logs"
    effect    = "Allow"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:*:*:*"]
  }

  statement {
    sid    = "ManageNightlySchedules"
    effect = "Allow"
    actions = [
      "scheduler:CreateSchedule",
      "scheduler:DeleteSchedule",
      "scheduler:GetSchedule",
    ]
    resources = ["arn:aws:scheduler:*:*:schedule/*/govee-step-*"]
  }

  statement {
    # ListSchedules operates over the whole group, not a single named
    # schedule, so AWS authorizes it against the group-wildcard resource
    # (schedule/*/*) regardless of NamePrefix - it can't be scoped down to
    # govee-step-* the way the other actions above can.
    sid       = "ListNightlySchedules"
    effect    = "Allow"
    actions   = ["scheduler:ListSchedules"]
    resources = ["arn:aws:scheduler:*:*:schedule/*/*"]
  }

  statement {
    sid       = "PassRoleToScheduler"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.scheduler.arn]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "govee-scene-lambda-permissions"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_permissions.json
}

# ---------------------------------------------------------------------------
# Lambda function
# ---------------------------------------------------------------------------
data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/../lambda_function.py"
  output_path = "${path.module}/.build/function.zip"
}

resource "aws_lambda_function" "govee_sunset_scene" {
  function_name    = local.function_name
  role             = aws_iam_role.lambda.arn
  handler          = "lambda_function.handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  environment {
    variables = {
      GOVEE_API_KEY       = var.govee_api_key
      GOVEE_DEVICE_FILTER = var.govee_device_filter
      GROUP_DEVICE_ID     = var.group_device_id
      LATITUDE            = var.latitude
      LONGITUDE           = var.longitude
      TIMEZONE            = var.timezone
      START_KELVIN        = tostring(var.start_kelvin)
      END_KELVIN          = tostring(var.end_kelvin)
      START_BRIGHTNESS    = tostring(var.start_brightness)
      EVENING_BRIGHTNESS  = tostring(var.evening_brightness)
      END_BRIGHTNESS      = tostring(var.end_brightness)
      STEP_COUNT          = tostring(var.step_count)
      FADE_STEP_COUNT     = tostring(var.fade_step_count)
      SCHEDULE_GROUP      = var.schedule_group
      SCHEDULER_ROLE_ARN  = aws_iam_role.scheduler.arn
      FUNCTION_ARN        = "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${local.function_name}"
    }
  }
}

# ---------------------------------------------------------------------------
# Recurring daily schedule that plans tonight's steps
# ---------------------------------------------------------------------------
resource "aws_scheduler_schedule" "plan_tonight" {
  name       = local.plan_schedule_name
  group_name = var.schedule_group

  schedule_expression          = var.plan_cron_utc
  schedule_expression_timezone = "UTC"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.govee_sunset_scene.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ action = "plan" })
  }
}
