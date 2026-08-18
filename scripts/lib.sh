#!/usr/bin/env bash
# Shared setup sourced by deploy-infra.sh and deploy-app.sh. Not meant to be
# run directly.

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Locally, config comes from .env. In CI, the same variables are injected
# directly into the environment by the GitHub Actions workflow, so .env is
# not required there.
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

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
  echo "No AWS region set - set AWS_REGION in .env locally, or as the AWS_REGION repo variable in CI." >&2
  exit 1
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
FUNCTION_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${FUNCTION_NAME}"
LAMBDA_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE_NAME}"
SCHEDULER_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${SCHEDULER_ROLE_NAME}"

require_vars() {
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      echo "Missing required value: $var (set it in .env locally, or as a GitHub secret/variable in CI)" >&2
      exit 1
    fi
  done
}
