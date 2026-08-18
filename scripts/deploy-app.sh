#!/usr/bin/env bash
# Packages lambda_function.py and creates/updates the Lambda function's code
# and configuration (env vars). Does NOT touch IAM roles or the EventBridge
# schedule - see deploy-infra.sh for that. On a brand new AWS account, run
# deploy-infra.sh at least once before this, since it creates the IAM role
# this function runs as.
#
# Requires: AWS CLI v2, configured credentials with permission to create/
# update Lambda functions.
#
# Usage:
#   cp .env.example .env   # then fill it in
#   ./scripts/deploy-app.sh
#
# Safe to re-run: updates the function code/config in place instead of
# failing on "already exists".

set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_vars GOVEE_API_KEY LATITUDE LONGITUDE TIMEZONE

echo "Account:  $ACCOUNT_ID"
echo "Region:   $REGION"
echo "Function: $FUNCTION_ARN"
echo

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

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

echo
echo "App deploy done."
echo
echo "Test the planner right now with:"
echo "  aws lambda invoke --function-name $FUNCTION_NAME --cli-binary-format raw-in-base64-out --payload '{\"action\":\"plan\"}' /tmp/out.json && cat /tmp/out.json"
echo
echo "Test a single bulb step right now with:"
echo "  aws lambda invoke --function-name $FUNCTION_NAME --cli-binary-format raw-in-base64-out --payload '{\"action\":\"run_step\",\"power\":\"on\",\"colorTemp\":3000}' /tmp/out.json && cat /tmp/out.json"
echo
echo "Watch logs with:"
echo "  aws logs tail /aws/lambda/$FUNCTION_NAME --follow"
