#!/usr/bin/env bash
# Deploys/updates the IAM roles and the recurring EventBridge schedule.
# Does NOT touch the Lambda function's code - see deploy-app.sh for that.
#
# Requires: AWS CLI v2, configured credentials with permission to create
# IAM roles and EventBridge Scheduler schedules.
#
# Usage:
#   cp .env.example .env   # then fill it in
#   ./scripts/deploy-infra.sh
#
# Safe to re-run: updates the roles/policies/schedule in place instead of
# failing on "already exists".

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_vars PLAN_CRON_UTC

echo "Account:  $ACCOUNT_ID"
echo "Region:   $REGION"
echo

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# 1. IAM role EventBridge Scheduler assumes to invoke the Lambda
# ---------------------------------------------------------------------------
sed "s#REPLACE_WITH_LAMBDA_ARN#${FUNCTION_ARN}#" \
  policies/scheduler-permissions-policy.json > "$WORKDIR/scheduler-permissions-policy.json"

if aws iam get-role --role-name "$SCHEDULER_ROLE_NAME" >/dev/null 2>&1; then
  echo "IAM role $SCHEDULER_ROLE_NAME already exists, updating policy..."
else
  echo "Creating IAM role $SCHEDULER_ROLE_NAME..."
  aws iam create-role \
    --role-name "$SCHEDULER_ROLE_NAME" \
    --assume-role-policy-document file://policies/scheduler-trust-policy.json >/dev/null
fi
aws iam put-role-policy \
  --role-name "$SCHEDULER_ROLE_NAME" \
  --policy-name "invoke-govee-lambda" \
  --policy-document "file://$WORKDIR/scheduler-permissions-policy.json"

# ---------------------------------------------------------------------------
# 2. IAM role the Lambda itself runs as
# ---------------------------------------------------------------------------
sed "s#REPLACE_WITH_SCHEDULER_ROLE_ARN#${SCHEDULER_ROLE_ARN}#" \
  policies/lambda-permissions-policy.json > "$WORKDIR/lambda-permissions-policy.json"

if aws iam get-role --role-name "$LAMBDA_ROLE_NAME" >/dev/null 2>&1; then
  echo "IAM role $LAMBDA_ROLE_NAME already exists, updating policy..."
else
  echo "Creating IAM role $LAMBDA_ROLE_NAME..."
  aws iam create-role \
    --role-name "$LAMBDA_ROLE_NAME" \
    --assume-role-policy-document file://policies/lambda-trust-policy.json >/dev/null
fi
aws iam put-role-policy \
  --role-name "$LAMBDA_ROLE_NAME" \
  --policy-name "govee-scene-lambda-permissions" \
  --policy-document "file://$WORKDIR/lambda-permissions-policy.json"

echo "Waiting for IAM role propagation..."
sleep 10

# ---------------------------------------------------------------------------
# 3. Recurring daily schedule that plans tonight's steps
# ---------------------------------------------------------------------------
TARGET="{\"Arn\":\"${FUNCTION_ARN}\",\"RoleArn\":\"${SCHEDULER_ROLE_ARN}\",\"Input\":\"{\\\"action\\\":\\\"plan\\\"}\"}"

if aws scheduler get-schedule --name "$PLAN_SCHEDULE_NAME" --group-name "$SCHEDULE_GROUP" >/dev/null 2>&1; then
  echo "Updating daily plan schedule..."
  aws scheduler update-schedule \
    --name "$PLAN_SCHEDULE_NAME" \
    --group-name "$SCHEDULE_GROUP" \
    --schedule-expression "$PLAN_CRON_UTC" \
    --schedule-expression-timezone "UTC" \
    --flexible-time-window '{"Mode":"OFF"}' \
    --target "$TARGET" >/dev/null
else
  echo "Creating daily plan schedule..."
  aws scheduler create-schedule \
    --name "$PLAN_SCHEDULE_NAME" \
    --group-name "$SCHEDULE_GROUP" \
    --schedule-expression "$PLAN_CRON_UTC" \
    --schedule-expression-timezone "UTC" \
    --flexible-time-window '{"Mode":"OFF"}' \
    --target "$TARGET" >/dev/null
fi

echo
echo "Infra deploy done (IAM roles + daily plan schedule)."
