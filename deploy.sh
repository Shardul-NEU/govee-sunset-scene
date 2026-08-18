#!/usr/bin/env bash
# Local convenience wrapper: runs the infra deploy then the app deploy, in
# the same order the two-stage CI/CD pipeline runs them in GitHub Actions
# (see scripts/deploy-infra.sh and scripts/deploy-app.sh, and
# .github/workflows/deploy-infra.yml / deploy-app.yml).
#
# Usage:
#   cp .env.example .env   # then fill it in
#   ./deploy.sh
#
# Safe to re-run: both stages update existing resources in place instead of
# failing on "already exists".

set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
  echo "Missing .env - copy .env.example to .env and fill it in first." >&2
  exit 1
fi

./scripts/deploy-infra.sh
./scripts/deploy-app.sh
