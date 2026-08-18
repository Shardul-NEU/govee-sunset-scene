# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A serverless AWS automation that runs 8 Govee smart bulbs on a sunset-to-bedtime
lighting curve: on and bright at real local sunset, warming/dimming through the
evening, reaching deep amber by 11pm, fading further to a dim night-light level,
then off at 1am. It re-derives the actual sunset time for the configured
coordinates every day, so the schedule shifts with the seasons automatically.
It does not talk to Claude/Anthropic once deployed — it's pure AWS + Govee's
cloud API.

Full user-facing setup/usage docs live in `README.md` — read it for the
step-by-step deploy flow. This file is about how the pieces fit together and
the non-obvious constraints, for making code changes.

## Architecture

**One Lambda function** (`lambda_function.py`), invoked by **EventBridge
Scheduler**, controlling bulbs via **Govee's cloud API** (not local/Bluetooth).
There is no database and no other compute — the Lambda's environment variables
are the entire config surface.

Three actions, dispatched from `handler()`:

- **`plan`** — runs once a day on a recurring schedule (`aws_scheduler_schedule.plan_tonight`, cron in `PLAN_CRON_UTC`, must fire before the year's earliest sunset). Looks up today's real sunset via sunrise-sunset.org, then computes and creates a batch of **one-time** EventBridge schedules (`govee-step-YYYYMMDD-NN`) for tonight, each with `ActionAfterCompletion="DELETE"` so they self-clean. Idempotent: it deletes any leftover `govee-step-*` schedules for the group before creating new ones, so re-running `plan` on the same day is safe.
- **`run_step`** — fired by each one-time schedule. Talks to the real Govee API to set power/color/brightness.
- **`list_devices`** — manual/ad-hoc only, never scheduled. Dumps every device (bulb *and* group) the API key can see; pass `{"verbose": true}` to also see each device's capability list. This is the tool for discovering `sku:deviceId` pairs for `GOVEE_DEVICE_FILTER` or a group's id for `GROUP_DEVICE_ID`.

### The two-phase nightly curve

`plan_tonight()` builds the schedule in two phases with different anchor
points — this split is deliberate, not incidental:

1. **Main ramp, sunset → 11pm** (`STEP_COUNT` points, default 6): color temp interpolates `START_KELVIN` → `END_KELVIN`; brightness interpolates `START_BRIGHTNESS` → `EVENING_BRIGHTNESS`.
2. **Fade, 11pm → ~1am** (`FADE_STEP_COUNT` points, default 3): color temp holds steady at `END_KELVIN` (already reached); brightness keeps interpolating `EVENING_BRIGHTNESS` → `END_BRIGHTNESS`. The last fade point lands 1 minute before 1am, not exactly at 1am, so it never collides in time with the off step.
3. **Off at 1am.**

If you change the curve shape, both phases (and their independent variable
sets) need to stay consistent — color temp variables only apply to phase 1,
brightness variables span both.

### Group vs. individual bulb control (important Govee API quirk)

Govee's device list (`GET /router/api/v1/user/devices`) returns **both** the
8 real bulbs (`sku: H6008`) *and* pseudo-devices for any groups configured in
the Govee Home app (`sku: SameModeGroup`) — there is no separate
groups-listing endpoint, and no field distinguishing them except `sku`.
**Group pseudo-devices only support `powerSwitch`** — no `colorTemperatureK`,
no `brightness`. This was verified empirically against the live API
(`list_devices` with `verbose: true`), not from Govee's docs, which don't
mention groups at all.

Consequently `run_step` takes a `power_mode` field to control how power is
applied, since power and color/brightness need different treatment:

- `"group"` — one call to `GROUP_DEVICE_ID` (the "Lights" group) flips power for all bulbs at once. Used only on the sunset (first) and 1am (last) steps, the only two moments a power state actually changes.
- `"skip"` — don't touch power at all; only set color/brightness on individual bulbs. Used on every step in between, since the bulbs are already on.
- `"individual"` (default when `power_mode` is omitted) — original per-bulb power fallback, kept for direct/manual invocations.

Every code path that iterates devices for color/brightness **must** exclude
`sku == GROUP_SKU` (`"SameModeGroup"`) — those pseudo-devices would otherwise
silently no-op (or error) on capabilities they don't have. `GOVEE_DEVICE_FILTER`
filtering happens independently of this and only applies to the individual-bulb
loop, not the group power call.

### Devices in this Govee account

From `{"action":"list_devices","verbose":true}` (device ids aren't secret,
but re-run this if bulbs are ever added/removed/renamed — this list will
drift):

| Name | sku | device id | capabilities |
|---|---|---|---|
| Desk Side 1 | H6008 | `37:C5:98:17:3C:74:CD:62` | powerSwitch, brightness, colorRgb, colorTemperatureK, lightScene, diyScene |
| Desk Side 2 | H6008 | `8C:C5:98:17:3C:74:79:A8` | powerSwitch, brightness, colorRgb, colorTemperatureK, lightScene, diyScene |
| Bed Lamp 1 | H6008 | `76:18:98:17:3C:71:9C:32` | powerSwitch, brightness, colorRgb, colorTemperatureK, lightScene, diyScene |
| Bed Lamp 2 | H6008 | `AF:6F:D0:C9:07:D6:51:90` | powerSwitch, brightness, colorRgb, colorTemperatureK, lightScene, diyScene |
| Fan 1 | H6008 | `05:83:5C:E7:53:A7:3A:FC` | powerSwitch, brightness, colorRgb, colorTemperatureK, lightScene, diyScene |
| Fan 2 | H6008 | `04:C7:5C:E7:53:AE:66:F2` | powerSwitch, brightness, colorRgb, colorTemperatureK, lightScene, diyScene |
| Fan 3 | H6008 | `07:BE:5C:E7:53:92:DE:7E` | powerSwitch, brightness, colorRgb, colorTemperatureK, lightScene, diyScene |
| Fan 4 | H6008 | `04:53:5C:E7:53:95:12:5E` | powerSwitch, brightness, colorRgb, colorTemperatureK, lightScene, diyScene |

Govee app groups (`sku: SameModeGroup`) — power-only, see the section above:

| Group | device id | Contains |
|---|---|---|
| Desk Side | `23198487` | Desk Side 1 + 2 |
| Bed Lamp | `23198574` | Bed Lamp 1 + 2 |
| Fan | `23521939` | Fan 1–4 |
| Lights | `12739459` | All 8 bulbs — **this is `GROUP_DEVICE_ID`'s current value** |

### Terraform layout

- `terraform/` — the real, single-stack config: both IAM roles, the Lambda (code *and* config together — Terraform owns the zip via `data.archive_file`, keyed off `lambda_function.py`'s hash), and the recurring `plan` schedule. There is no separate "deploy the code" step — any Lambda code change goes through `terraform apply` like everything else.
- `terraform/bootstrap/` — a **separate, independent root module** (own provider block, own state) that only creates the S3 bucket + DynamoDB lock table `terraform/` uses as its remote backend. Chicken-and-egg: it can't itself use that backend, so it keeps local state. Apply it once per AWS account, by hand, never from CI. Never wire this into the main config or the CI workflows.
- Because the main config's backend is defined as an empty `backend "s3" {}` block, `terraform init` always needs `-backend-config=backend.hcl` (gitignored, per-machine — see `backend.hcl.example`) or the equivalent `-backend-config="key=value"` flags CI passes explicitly.

### CI/CD

Two workflows, both required to pass before merge (branch protection on
`master`, enforced even for the repo admin — no direct pushes, ever):

- `.github/workflows/ci.yml` (job `checks`) — Python syntax check + `terraform fmt -check` + `terraform validate` for both `terraform/` and `terraform/bootstrap/`.
- `.github/workflows/terraform.yml` — `plan` job runs on pull requests; `apply` job runs on push to `master` (i.e., after merge) and on manual `workflow_dispatch`. Path-filtered to `terraform/**` and `lambda_function.py`, explicitly excluding `terraform/bootstrap/**`. Optional numeric config vars are passed as `${{ vars.X || <default> }}` in the `env:` block — GitHub returns `''` for an unset repo variable, and an empty string fed to a Terraform `number` variable is a hard error, not "use the default." Keep that fallback pattern if you add more optional numeric variables.

All Terraform inputs come from GitHub Actions **secrets** (`AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY`, `GOVEE_API_KEY`) and **variables** (everything else,
including `TF_STATE_BUCKET`/`TF_LOCK_TABLE` from the bootstrap output and
`GROUP_DEVICE_ID`) — never committed anywhere. Locally, the equivalent lives
in gitignored `terraform/terraform.tfvars` / `terraform/backend.hcl`.

## Commands

All from `terraform/` unless noted.

```
terraform init -backend-config=backend.hcl   # first time / after backend.hcl changes
terraform fmt -check -diff                    # formatting check (CI enforces this)
terraform validate                            # also run against terraform/bootstrap/
terraform plan
terraform apply
```

Testing the Lambda directly (bypasses the schedule, hits real bulbs/API):

```
aws lambda invoke --function-name govee-sunset-scene \
  --cli-binary-format raw-in-base64-out \
  --payload '{"action":"plan"}' /tmp/out.json && cat /tmp/out.json

aws lambda invoke --function-name govee-sunset-scene \
  --cli-binary-format raw-in-base64-out \
  --payload '{"action":"run_step","power":"on","colorTemp":3000,"brightness":50,"power_mode":"skip"}' \
  /tmp/out.json && cat /tmp/out.json

aws lambda invoke --function-name govee-sunset-scene \
  --cli-binary-format raw-in-base64-out \
  --payload '{"action":"list_devices","verbose":true}' /tmp/out.json && cat /tmp/out.json

aws logs tail /aws/lambda/govee-sunset-scene --follow
```

There is no automated test suite for `lambda_function.py` — CI only checks it
compiles (`python -m py_compile lambda_function.py`). Validate behavior
changes with real `aws lambda invoke` calls against the deployed function, as
above.

## Workflow for making changes

Every change (Terraform or Lambda code) goes through the same loop, since
`master` is protected:

```
git checkout -b <branch>
# edit terraform/ and/or lambda_function.py
terraform fmt && terraform validate
terraform plan    # review against the real deployed state
terraform apply   # optional: apply locally first to test against real bulbs before opening a PR
git add -A && git commit -m "..." && git push -u origin <branch>
gh pr create ...
# wait for `checks` and `plan` to pass, then
gh pr merge <n> --squash --delete-branch
```

Merging triggers `apply` in CI automatically, reconciling against whatever
was already applied locally — if you already `terraform apply`'d your change
before opening the PR, the CI apply will be a no-op confirmation, not a
surprise.
