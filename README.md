# Govee sunset-to-bedtime lighting automation

Runs your 8 Govee bulbs on a serverless AWS schedule: on at real local
sunset in warm white, gradually warmer/more amber through the evening,
holding deep amber from midnight, off at 1am. No always-on device, and it
doesn't run through Claude at all once deployed - it's pure AWS, effectively
free (well inside the Lambda/EventBridge/Scheduler free tiers for this
volume of calls), and keeps your Govee API key on your own AWS account only.

## How it works

- **One Lambda function** (`lambda_function.py`) with two actions:
  - `plan` - runs once a day, well before sunset. Looks up today's real
    sunset time for your coordinates (via the free sunrise-sunset.org API),
    then creates a handful of one-time EventBridge Scheduler entries for
    tonight: sunset, a few warming steps, local midnight, and 1am-off. Each
    one-time entry deletes itself right after it fires.
  - `run_step` - fired by each of those one-time entries. Calls Govee's own
    cloud API directly to set color temperature (or turn bulbs off) on
    every bulb your API key can see.
- **EventBridge Scheduler** provides both the daily recurring trigger for
  `plan` and the disposable nightly triggers for `run_step`.
- Two small IAM roles: one lets EventBridge Scheduler invoke your Lambda,
  one lets your Lambda create/delete tonight's schedules and write logs.

Nothing here talks to Claude or any Anthropic service - once deployed it
runs indefinitely on its own, and you can turn it off any night just by
disabling the `govee-plan-tonight` schedule in the AWS console.

## 1. Get a Govee API key

Govee Home app (iPhone) -> profile icon (bottom right) -> **Settings** ->
**About Us** -> **Apply for API Key**. Approval is usually near-instant to
a day. You'll get a key that looks like a UUID.

## 2. Get your coordinates

Google Maps -> right-click your house -> the top line of the context menu
is your `lat, lng`. Or just say "what are the coordinates of <address>" to
any maps app.

## 3. Fill in your config

```
cp .env.example .env
```

Edit `.env`:
- `GOVEE_API_KEY` - from step 1
- `LATITUDE` / `LONGITUDE` - from step 2
- `TIMEZONE` - your IANA timezone, e.g. `America/Chicago`
- `PLAN_CRON_UTC` - a UTC cron expression for a time that is *always*
  before your earliest sunset of the year (winter). For US timezones, the
  default `cron(0 18 * * ? *)` (18:00 UTC = 12-1pm local depending on
  season/DST) is safe. If you're elsewhere, pick a UTC hour that maps to
  early afternoon local time.
- `START_KELVIN` / `END_KELVIN` / `STEP_COUNT` - tune the warmth curve if
  you want. Defaults: 4300K (warm white) at sunset down to 2200K (deep
  amber/candlelight) at midnight, in 6 steps.
- `GOVEE_DEVICE_FILTER` - leave blank to control all 8 bulbs. Only set this
  if you later add other Govee devices to the account you don't want this
  automation touching.

`.env` stays on your machine - `deploy.sh` reads it locally to configure
the Lambda's environment variables in AWS. It is not sent anywhere else.

## 4. Deploy

Requires the AWS CLI v2, logged in with a user/role that can create IAM
roles, Lambda functions, and EventBridge Scheduler schedules.

```
./deploy.sh
```

This runs the two deploy stages locally, in order (see below), and is safe
to re-run any time you change `.env` - it updates existing resources in
place rather than erroring.

## CI/CD

Deploys are split into two independent stages, each with its own script and
GitHub Actions workflow:

| Stage | Script | Workflow | Triggered by changes to |
|---|---|---|---|
| Infra (IAM roles, EventBridge schedule) | `scripts/deploy-infra.sh` | `.github/workflows/deploy-infra.yml` | `policies/**`, `scripts/deploy-infra.sh`, `scripts/lib.sh` |
| App (Lambda code + config) | `scripts/deploy-app.sh` | `.github/workflows/deploy-app.yml` | `lambda_function.py`, `scripts/deploy-app.sh`, `scripts/lib.sh` |

`.github/workflows/ci.yml` runs on every pull request (Python syntax check,
IAM policy JSON validation, shellcheck) and must pass before merging.

**`master` is protected** - no direct pushes; all changes go through a pull
request, and the CI checks above must pass before merge.

Both deploy workflows run automatically on merge to `master`, only when the
relevant paths changed, using AWS credentials and config stored as GitHub
Actions secrets/variables (Settings -> Secrets and variables -> Actions):

Secrets (sensitive):
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` - an AWS user/role with
  permission to manage IAM roles, Lambda, and EventBridge Scheduler.
- `GOVEE_API_KEY` - from step 1 above.

Variables (not sensitive):
- `AWS_REGION`
- `LATITUDE`, `LONGITUDE`, `TIMEZONE`
- `PLAN_CRON_UTC`
- `GOVEE_DEVICE_FILTER`, `START_KELVIN`, `END_KELVIN`, `STEP_COUNT` (optional
  - the scripts fall back to the same defaults as `.env.example`)

You can also run either workflow manually from the Actions tab
(`workflow_dispatch`) without changing any files.

## 5. Test before trusting it overnight

```
aws lambda invoke --function-name govee-sunset-scene \
  --cli-binary-format raw-in-base64-out \
  --payload '{"action":"run_step","power":"on","colorTemp":3000}' \
  /tmp/out.json && cat /tmp/out.json
```

Your bulbs should immediately jump to ~3000K. Then try:

```
aws lambda invoke --function-name govee-sunset-scene \
  --cli-binary-format raw-in-base64-out \
  --payload '{"action":"plan"}' \
  /tmp/out.json && cat /tmp/out.json
```

This prints tonight's actual planned schedule (local times + Kelvin values)
without waiting for the real trigger - check that the sunset time and steps
look right for your location before letting it run unattended. You can see
the schedules it created in the AWS Console under EventBridge -> Scheduler,
or list them with:

```
aws scheduler list-schedules --group-name default --name-prefix govee-step-
```

Watch what happens in real time (useful the first night):

```
aws logs tail /aws/lambda/govee-sunset-scene --follow
```

## Costs

At roughly 1 `plan` call + 7 `run_step` calls per night (~30 Lambda
invocations/month, each touching 8 bulbs with 2 API calls apiece), this is
comfortably inside AWS's always-free Lambda and EventBridge Scheduler
tiers. Expect $0/month.

## Adjusting later

- Change the warmth curve: edit `START_KELVIN` / `END_KELVIN` / `STEP_COUNT`
  in `.env` and re-run `./deploy.sh`.
- Pause it: disable the schedule -
  `aws scheduler update-schedule --name govee-plan-tonight --group-name default --state DISABLED --schedule-expression "$PLAN_CRON_UTC" --schedule-expression-timezone UTC --flexible-time-window '{"Mode":"OFF"}' --target '...'`
  (easiest to just toggle it off in the AWS Console instead).
- Remove it entirely: delete the `govee-sunset-scene` Lambda, the
  `govee-plan-tonight` schedule, and the two IAM roles
  (`govee-scene-lambda-role`, `govee-scene-scheduler-role`).

## Notes / known limitations

- Sunset time comes from the free sunrise-sunset.org API. If that API is
  ever unreachable when `plan` runs, the code falls back to a fixed
  7:30pm-local sunset for that night rather than skipping the automation
  entirely (see `_get_sunset_utc` in `lambda_function.py`).
- Brightness is left untouched - only color temperature changes. If you
  also want brightness to dim toward midnight, say so and I'll extend the
  script; it's a small addition.
- If a bulb model doesn't support Kelvin color temperature (rare for Govee
  color bulbs, but some strip-only SKUs use RGB instead), that bulb is
  still turned on/off correctly but its color step is skipped - check
  CloudWatch logs if a specific bulb doesn't seem to respond.
