#!/usr/bin/env bash
# Deploys the Govee sunset-scene automation to your own AWS account.
# Requires: AWS CLI v2, configured credentials with permission to create
# IAM roles, Lambda functions, and EventBridge Scheduler schedules.
#
# Usage:
#   cp .env.example .env   # then fill it in
#   ./deploy.sh
#
# Safe to re-run: updates the function code/config and the recurring
# schedule in place instead of failing on "already exists".

set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
  echo "Missing .env - copy .env.example to .env and fill it in first." >&2
  exit 1
fi
set -a
source .env
set +a

for var in GOVEE_API_KEY LATITUDE LONGITUDE TIMEZONE PLAN_CRON_UTC; do
  if [[ -z "${!var:-}" ]]; then
    echo "Missing required value: $var (set it in .env)" >&2
    exit 1
  fi
done

[[ -n "${AWS_REGION:-}" ]] && export AWS_REGION
[[ -n "${AWS_PROFILE:-}" ]] && export AWS_PROFILE

FUNCTION_NAME="govee-sunset-scene"
LAMBDA_ROLE_NAME="govee-scene-lambda-role"
SCHEDULER_ROLE_NAME="govee-scene-scheduler-role"
SCHEDULE_GROUP="${SCHEDULE_GROUP:-default}"
PLAN_SCHEDULE_NAME="govee-plan-tonight"

REGION="$(aws configure get region 2>/dev/null || true)"
[[ -n "${AWS_REGION:-}" ]] && REGION="$AWS_REGION"
if [[ -z "$REGION" ]]; then
  echo "No AWS region set - set AWS_REGION in .env or run 'aws configure'." >&2
  exit 1
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
FUNCTION_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${FUNCTION_NAME}"
LAMBDA_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE_NAME}"
SCHEDULER_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${SCHEDULER_ROLE_NAME}"

echo "Account:  $ACCOUNT_ID"
echo "Region:   $REGION"
echo "Function: $FUNCTION_ARN"
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
# 3. Package and create/update the Lambda function
# ---------------------------------------------------------------------------
echo "Packaging function.zip..."
zip -j "$WORKDIR/function.zip" lambda_function.py >/dev/null

ENV_VARS="Variables={GOVEE_API_KEY=${GOVEE_API_KEY},GOVEE_DEVICE_FILTER=${GOVEE_DEVICE_FILTER:-},LATITUDE=${LATITUDE},LONGITUDE=${LONGITUDE},TIMEZONE=${TIMEZONE},START_KELVIN=${START_KELVIN:-4300},END_KELVIN=${END_KELVIN:-2200},STEP_COUNT=${STEP_COUNT:-6},SCHEDULE_GROUP=${SCHEDULE_GROUP},SCHEDULER_ROLE_ARN=${SCHEDULER_ROLE_ARN},FUNCTION_ARN=${FUNCTION_ARN}}"

if aws lambda get-function --function-name "$FUNCTION_NAME" >/dev/null 2>&1; then
  echo "Function exists, updating code and configuration..."
  aws lambda update-function-code \
    --function-name "$FUNCTION_NAME" \
    --zip-file "fileb://$WORKDIR/function.zip" >/dev/null
  aws lambda wait function-updated --function-name "$FUNCTION_NAME"
  aws lambda update-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --timeout 30 \
    --environment "$ENV_VARS" >/dev/null
else
  echo "Creating function $FUNCTION_NAME..."
  aws lambda create-function \
    --function-name "$FUNCTION_NAME" \
    --runtime python3.12 \
    --role "$LAMBDA_ROLE_ARN" \
    --handler lambda_function.handler \
    --timeout 30 \
    --zip-file "fileb://$WORKDIR/function.zip" \
    --environment "$ENV_VARS" >/dev/null
  aws lambda wait function-active --function-name "$FUNCTION_NAME"
fi

# ---------------------------------------------------------------------------
# 4. Recurring daily schedule that plans tonight's steps
# ---------------------------------------------------------------------------
if aws scheduler get-schedule --name "$PLAN_SCHEDULE_NAME" --group-name "$SCHEDULE_GROUP" >/dev/null 2>&1; then
  echo "Updating daily plan schedule..."
  aws scheduler update-schedule \
    --name "$PLAN_SCHEDULE_NAME" \
    --group-name "$SCHEDULE_GROUP" \
    --schedule-expression "$PLAN_CRON_UTC" \
    --schedule-expression-timezone "UTC" \
    --flexible-time-window '{"Mode":"OFF"}' \
    --target "{\"Arn\":\"${FUNCTION_ARN}\",\"RoleArn\":\"${SCHEDULER_ROLE_ARN}\",\"Input\":\"{\\\"action\\\":\\\"plan\\\"}\"}" >/dev/null
else
  echo "Creating daily plan schedule..."
  aws scheduler create-schedule \
    --name "$PLAN_SCHEDULE_NAME" \
    --group-name "$SCHEDULE_GROUP" \
    --schedule-expression "$PLAN_CRON_UTC" \
    --schedule-expression-timezone "UTC" \
    --flexible-time-window '{"Mode":"OFF"}' \
    --target "{\"Arn\":\"${FUNCTION_ARN}\",\"RoleArn\":\"${SCHEDULER_ROLE_ARN}\",\"Input\":\"{\\\"action\\\":\\\"plan\\\"}\"}" >/dev/null
fi

echo
echo "Done."
echo
echo "Test the planner right now with:"
echo "  aws lambda invoke --function-name $FUNCTION_NAME --cli-binary-format raw-in-base64-out --payload '{\"action\":\"plan\"}' /tmp/out.json && cat /tmp/out.json"
echo
echo "Test a single bulb step right now with:"
echo "  aws lambda invoke --function-name $FUNCTION_NAME --cli-binary-format raw-in-base64-out --payload '{\"action\":\"run_step\",\"power\":\"on\",\"colorTemp\":3000}' /tmp/out.json && cat /tmp/out.json"
echo
echo "Watch logs with:"
echo "  aws logs tail /aws/lambda/$FUNCTION_NAME --follow"
