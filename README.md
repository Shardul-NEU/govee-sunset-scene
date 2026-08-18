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

## 3. One-time: create the Terraform state backend

Terraform needs somewhere to keep its state file. `terraform/bootstrap` is a
tiny, separate Terraform config that creates an S3 bucket + DynamoDB lock
table for this - run it once, by hand, from your machine (never from CI):

```
cd terraform/bootstrap
terraform init
terraform apply -var="state_bucket_name=<a globally unique bucket name>" -var="aws_region=<your region>"
terraform output
```

Then, back in `terraform/`:

```
cd ..
cp backend.hcl.example backend.hcl
```

Edit `backend.hcl` with the bucket name/region from the output above.

## 4. Fill in your config

```
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:
- `aws_region`
- `govee_api_key` - from step 1
- `latitude` / `longitude` - from step 2
- `timezone` - your IANA timezone, e.g. `America/Chicago`
- `plan_cron_utc` - a UTC cron expression for a time that is *always*
  before your earliest sunset of the year (winter). For US timezones, the
  default `cron(0 18 * * ? *)` (18:00 UTC = 12-1pm local depending on
  season/DST) is safe. If you're elsewhere, pick a UTC hour that maps to
  early afternoon local time.
- `start_kelvin` / `end_kelvin` / `step_count` - tune the warmth curve if
  you want. Defaults: 4300K (warm white) at sunset down to 2200K (deep
  amber/candlelight) at midnight, in 6 steps.
- `start_brightness` / `end_brightness` - brightness percent (1-100) over
  the same curve. Defaults: 60% at sunset down to 30% at midnight.
- `govee_device_filter` - leave blank to control all 8 bulbs. Only set this
  if you later add other Govee devices to the account you don't want this
  automation touching.

`terraform.tfvars` and `backend.hcl` stay on your machine - they are
gitignored. In CI, the same values come from GitHub Actions secrets/
variables instead (see CI/CD below).

## 5. Deploy

Requires Terraform >= 1.5 and the AWS CLI v2, logged in with a user/role
that can create IAM roles, Lambda functions, and EventBridge Scheduler
schedules.

```
cd terraform
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

Safe to re-run any time you change `terraform.tfvars` or `lambda_function.py`
- Terraform diffs against the real AWS state and only changes what's
different.

## CI/CD

Terraform is the single source of truth for the whole stack - IAM roles,
the Lambda function (code + config), and the EventBridge schedule. Two
GitHub Actions workflows drive it:

- `.github/workflows/ci.yml` - on every pull request: Python syntax check,
  `terraform fmt -check`, `terraform validate`.
- `.github/workflows/terraform.yml` - `terraform plan` on every pull request
  that touches `terraform/**` or `lambda_function.py`; `terraform apply
  -auto-approve` automatically on merge to `master`. Never touches
  `terraform/bootstrap` (that's the one-time by-hand step above).

Both workflow's checks must pass before a PR can merge - **`master` is
protected**: no direct pushes, all changes go through a pull request.

The `terraform` workflow needs AWS credentials and your config as GitHub
Actions secrets/variables (Settings -> Secrets and variables -> Actions):

Secrets (sensitive):
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` - an AWS user/role with
  permission to manage IAM roles, Lambda, EventBridge Scheduler, and to
  read/write the state bucket + lock table.
- `GOVEE_API_KEY` - from step 1 above.

Variables (not sensitive):
- `AWS_REGION`
- `TF_STATE_BUCKET`, `TF_LOCK_TABLE` - from the bootstrap output in step 3.
- `LATITUDE`, `LONGITUDE`, `TIMEZONE`
- `PLAN_CRON_UTC`
- `GOVEE_DEVICE_FILTER`, `START_KELVIN`, `END_KELVIN`, `START_BRIGHTNESS`,
  `END_BRIGHTNESS`, `STEP_COUNT` (optional - Terraform falls back to the
  same defaults as `terraform.tfvars.example`)

You can also run the `terraform` workflow manually from the Actions tab
(`workflow_dispatch`) without changing any files.

## 6. Test before trusting it overnight

```
aws lambda invoke --function-name govee-sunset-scene \
  --cli-binary-format raw-in-base64-out \
  --payload '{"action":"run_step","power":"on","colorTemp":3000,"brightness":50}' \
  /tmp/out.json && cat /tmp/out.json
```

Your bulbs should immediately jump to ~3000K at 50% brightness. Then try:

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

- Change the warmth curve: edit `start_kelvin` / `end_kelvin` / `step_count`
  in `terraform.tfvars` (or the matching GitHub variables for CI) and
  re-apply.
- Change the brightness curve: edit `start_brightness` / `end_brightness`
  the same way.
- Pause it: easiest to toggle the `govee-plan-tonight` schedule off in the
  AWS Console (EventBridge -> Scheduler) rather than changing Terraform.
- Remove it entirely: `terraform destroy` (from `terraform/`, with the same
  backend/tfvars). This deletes the Lambda, the `govee-plan-tonight`
  schedule, and both IAM roles. It does not touch the state bucket/lock
  table created by `terraform/bootstrap` - destroy those separately if you
  want them gone too.

## Notes / known limitations

- Sunset time comes from the free sunrise-sunset.org API. If that API is
  ever unreachable when `plan` runs, the code falls back to a fixed
  7:30pm-local sunset for that night rather than skipping the automation
  entirely (see `_get_sunset_utc` in `lambda_function.py`).
- If a bulb model doesn't support Kelvin color temperature or brightness
  (rare for Govee color bulbs, but some strip-only SKUs use RGB instead),
  that bulb is still turned on/off correctly but the unsupported step is
  skipped - check CloudWatch logs if a specific bulb doesn't seem to
  respond.
