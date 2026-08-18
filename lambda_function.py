"""
Govee sunset-to-bedtime lighting automation.

One Lambda, two "actions", both driven by EventBridge Scheduler:

  action = "plan"      -> runs once a day (recurring schedule you create at
                           deploy time). Looks up TODAY's real sunset time
                           for your lat/long, then creates a handful of
                           one-time EventBridge schedules for tonight:
                             sunset            -> warm white, on
                             ... N steps ...   -> progressively warmer
                             local midnight    -> deepest amber, holds
                             local 1:00 AM     -> off
                           Each one-time schedule deletes itself after firing.

  action = "run_step"  -> fired by one of those one-time schedules. Talks to
                           the real Govee cloud API and applies the
                           requested color temperature (or turns the bulbs
                           off) on every bulb on your account (or a filtered
                           subset -- see DEVICE_FILTER below).

Environment variables (set these on the Lambda, never hard-code secrets here):
  GOVEE_API_KEY   (required) - your personal Govee Developer API key
  LATITUDE        (required) - decimal degrees, e.g. "30.2672"
  LONGITUDE       (required) - decimal degrees, e.g. "-97.7431"
  TIMEZONE        (required) - IANA tz name, e.g. "America/Chicago"
  SCHEDULER_ROLE_ARN   (required) - IAM role EventBridge Scheduler assumes
                                     to invoke this Lambda (see terraform/)
  FUNCTION_ARN         (required) - this Lambda's own ARN (see terraform/)
  DEVICE_FILTER   (optional) - comma-separated "sku:deviceId" pairs to
                                limit which bulbs are controlled. Leave
                                unset to control every device the API key
                                can see.
  START_KELVIN    (optional, default 4300) - color temp at sunset
  END_KELVIN      (optional, default 2200)  - color temp at local midnight
  STEP_COUNT      (optional, default 6) - number of points between sunset
                                and midnight (inclusive of both ends)
  SCHEDULE_GROUP  (optional, default "default") - EventBridge Scheduler group
"""

import json
import os
import time
import uuid
import urllib.request
import urllib.error
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import boto3

GOVEE_BASE = "https://openapi.api.govee.com"
SUNSET_API = "https://api.sunrise-sunset.org/json"

scheduler = boto3.client("scheduler")


# --------------------------------------------------------------------------
# Small HTTP helper (stdlib only, no third-party deps to package)
# --------------------------------------------------------------------------
def _http_json(method, url, headers=None, body=None, timeout=10):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode("utf-8")
        return json.loads(raw) if raw else {}


# --------------------------------------------------------------------------
# action = "plan": figure out tonight's real sunset and schedule the steps
# --------------------------------------------------------------------------
def plan_tonight(event, context):
    lat = os.environ["LATITUDE"]
    lng = os.environ["LONGITUDE"]
    tz = ZoneInfo(os.environ["TIMEZONE"])
    start_k = int(os.environ.get("START_KELVIN", "4300"))
    end_k = int(os.environ.get("END_KELVIN", "2200"))
    step_count = int(os.environ.get("STEP_COUNT", "6"))
    group = os.environ.get("SCHEDULE_GROUP", "default")
    function_arn = os.environ["FUNCTION_ARN"]
    scheduler_role_arn = os.environ["SCHEDULER_ROLE_ARN"]

    sunset_utc = _get_sunset_utc(lat, lng)
    sunset_local = sunset_utc.astimezone(tz)

    # Midnight and 1am *after* tonight's sunset, in local time.
    next_day = sunset_local.date() + timedelta(days=1)
    midnight_local = datetime(next_day.year, next_day.month, next_day.day, 0, 0, 0, tzinfo=tz)
    one_am_local = midnight_local + timedelta(hours=1)

    # Build the warm-to-amber steps between sunset and midnight.
    steps = []
    span = (midnight_local - sunset_local) / max(step_count - 1, 1)
    for i in range(step_count):
        when = sunset_local + span * i
        frac = i / max(step_count - 1, 1)
        kelvin = round(start_k + (end_k - start_k) * frac)
        steps.append((when, {"action": "run_step", "power": "on", "colorTemp": kelvin}))

    # Off at 1am.
    steps.append((one_am_local, {"action": "run_step", "power": "off"}))

    # Clean up any leftover schedules from a previous run today (idempotency).
    _delete_existing_step_schedules(group)

    date_tag = sunset_local.strftime("%Y%m%d")
    created = []
    for i, (when_local, payload) in enumerate(steps):
        when_utc = when_local.astimezone(timezone.utc)
        name = f"govee-step-{date_tag}-{i:02d}"
        scheduler.create_schedule(
            Name=name,
            GroupName=group,
            ScheduleExpression=f"at({when_utc.strftime('%Y-%m-%dT%H:%M:%S')})",
            ScheduleExpressionTimezone="UTC",
            FlexibleTimeWindow={"Mode": "OFF"},
            ActionAfterCompletion="DELETE",
            Target={
                "Arn": function_arn,
                "RoleArn": scheduler_role_arn,
                "Input": json.dumps(payload),
            },
        )
        created.append({"name": name, "when_local": when_local.isoformat(), "payload": payload})

    return {"sunset_local": sunset_local.isoformat(), "scheduled": created}


def _get_sunset_utc(lat, lng):
    try:
        resp = _http_json(
            "GET",
            f"{SUNSET_API}?lat={lat}&lng={lng}&formatted=0",
            timeout=8,
        )
        sunset_str = resp["results"]["sunset"]  # ISO8601 UTC, e.g. 2026-08-18T01:23:45+00:00
        return datetime.fromisoformat(sunset_str)
    except Exception as e:  # noqa: BLE001 - degrade gracefully rather than doing nothing tonight
        print(f"WARNING: sunset lookup failed ({e}); falling back to 7:30pm local")
        tz = ZoneInfo(os.environ["TIMEZONE"])
        now_local = datetime.now(tz)
        fallback = now_local.replace(hour=19, minute=30, second=0, microsecond=0)
        return fallback.astimezone(timezone.utc)


def _delete_existing_step_schedules(group):
    paginator = scheduler.get_paginator("list_schedules")
    for page in paginator.paginate(GroupName=group, NamePrefix="govee-step-"):
        for s in page.get("Schedules", []):
            try:
                scheduler.delete_schedule(Name=s["Name"], GroupName=group)
            except Exception as e:  # noqa: BLE001
                print(f"WARNING: could not delete stale schedule {s['Name']}: {e}")


# --------------------------------------------------------------------------
# action = "run_step": actually talk to the Govee cloud API
# --------------------------------------------------------------------------
def run_step(event, context):
    api_key = os.environ["GOVEE_API_KEY"]
    power = event.get("power", "on")
    color_temp = event.get("colorTemp")
    device_filter = _parse_device_filter(os.environ.get("DEVICE_FILTER", ""))

    devices = _list_devices(api_key)
    results = []
    for d in devices:
        sku, device_id = d["sku"], d["device"]
        if device_filter and (sku, device_id) not in device_filter:
            continue

        caps = {c["instance"]: c for c in d.get("capabilities", [])}
        results.append(_set_power(api_key, sku, device_id, power == "on"))
        time.sleep(0.2)

        if power == "on" and color_temp is not None and "colorTemperatureK" in caps:
            rng = caps["colorTemperatureK"].get("parameters", {}).get("range", {})
            clamped = max(rng.get("min", 2000), min(rng.get("max", 9000), color_temp))
            results.append(_set_color_temp(api_key, sku, device_id, clamped))
            time.sleep(0.2)

    return {"power": power, "colorTemp": color_temp, "devices_touched": len(results)}


def _parse_device_filter(raw):
    pairs = set()
    for entry in raw.split(","):
        entry = entry.strip()
        if not entry:
            continue
        sku, _, device_id = entry.partition(":")
        pairs.add((sku.strip(), device_id.strip()))
    return pairs


def _list_devices(api_key):
    resp = _http_json(
        "GET",
        f"{GOVEE_BASE}/router/api/v1/user/devices",
        headers={"Govee-API-Key": api_key},
    )
    return resp.get("data", [])


def _control(api_key, sku, device_id, capability):
    body = {
        "requestId": str(uuid.uuid4()),
        "payload": {"sku": sku, "device": device_id, "capability": capability},
    }
    try:
        resp = _http_json(
            "POST",
            f"{GOVEE_BASE}/router/api/v1/device/control",
            headers={"Govee-API-Key": api_key},
            body=body,
        )
        return {"device": device_id, "ok": True, "response": resp}
    except urllib.error.HTTPError as e:
        return {"device": device_id, "ok": False, "error": f"{e.code} {e.read().decode('utf-8', 'ignore')}"}
    except Exception as e:  # noqa: BLE001
        return {"device": device_id, "ok": False, "error": str(e)}


def _set_power(api_key, sku, device_id, on):
    return _control(
        api_key, sku, device_id,
        {"type": "devices.capabilities.on_off", "instance": "powerSwitch", "value": 1 if on else 0},
    )


def _set_color_temp(api_key, sku, device_id, kelvin):
    return _control(
        api_key, sku, device_id,
        {"type": "devices.capabilities.color_setting", "instance": "colorTemperatureK", "value": kelvin},
    )


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------
def handler(event, context):
    action = event.get("action")
    print(f"invoked with action={action} event={json.dumps(event)}")
    if action == "plan":
        return plan_tonight(event, context)
    if action == "run_step":
        return run_step(event, context)
    raise ValueError(f"Unknown action: {action!r} (expected 'plan' or 'run_step')")
