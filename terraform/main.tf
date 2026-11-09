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
    resources = ["arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${local.function_name}"]
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
# The Lambda function and the recurring plan_tonight schedule were removed
# to stop the automation entirely. Revert this commit to restore them.
# ---------------------------------------------------------------------------
