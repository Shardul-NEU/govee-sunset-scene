"""
Govee sunset-to-bedtime lighting automation.

One Lambda, three "actions". "plan" and "run_step" are driven by
EventBridge Scheduler; "list_devices" is for manual/ad-hoc invocation:

  action = "plan"      -> runs once a day (recurring schedule you create at
                           deploy time). Looks up TODAY's real sunset time
                           for your lat/long, then creates a handful of
                           one-time EventBridge schedules for tonight:
                             sunset            -> warm white, on, bright
                             ... N steps ...   -> progressively warmer/dimmer
                             local 11:00 PM    -> deep amber, evening dim
                             ... M steps ...   -> keeps warming to night_kelvin,
                                                  keeps dimming
                             a few minutes before local 1:00 AM -> last fade
                                                  point (deepest amber/dimmest)
                             local 1:00 AM     -> off
                           Each one-time schedule deletes itself after firing.

  action = "run_step"  -> fired by one of those one-time schedules. Talks to
                           the real Govee cloud API and applies the
                           requested color temperature (or turns the bulbs
                           off) on every bulb on your account (or a filtered
                           subset -- see DEVICE_FILTER below).

  action = "list_devices" -> returns sku/device id/name for every bulb the
                           API key can see. Handy for figuring out
                           GOVEE_DEVICE_FILTER pairs.

Environment variables (set these on the Lambda, never hard-code secrets here):
  GOVEE_API_KEY   (required) - your personal Govee Developer API key
  LATITUDE        (required) - decimal degrees, e.g. "30.2672"
  LONGITUDE       (required) - decimal degrees, e.g. "-97.7431"
  TIMEZONE        (required) - IANA tz name, e.g. "America/Chicago"
  SCHEDULER_ROLE_ARN   (required) - IAM role EventBridge Scheduler assumes
                                     to invoke this Lambda (see terraform/)
  FUNCTION_ARN         (required) - this Lambda's own ARN (see terraform/)
  GROUP_DEVICE_ID (required) - device id of the Govee app "group" (sku
                                SameModeGroup) containing all controlled
                                bulbs. Used for the single on/off call at
                                sunset and 1am instead of one call per bulb.
                                Find it with action=list_devices.
  DEVICE_FILTER   (optional) - comma-separated "sku:deviceId" pairs to
                                limit which bulbs are controlled. Leave
                                unset to control every device the API key
                                can see.
  START_KELVIN    (optional, default 4300) - color temp at sunset
  END_KELVIN      (optional, default 2200)  - color temp at 11pm
  NIGHT_KELVIN    (optional, default 2000) - color temp at the last fade
                                point (a few minutes before 1am); the fade
                                phase keeps warming color temp from END_KELVIN
                                down to this instead of holding it flat
  START_BRIGHTNESS   (optional, default 60) - brightness % at sunset
  EVENING_BRIGHTNESS (optional, default 30) - brightness % at 11pm
  END_BRIGHTNESS     (optional, default 10) - brightness % just before 1am
                                               shutoff
  STEP_COUNT      (optional, default 6) - number of points between sunset
                                and 11pm (inclusive of both ends)
  FADE_STEP_COUNT (optional, default 3) - number of extra warming/dimming
                                points between 11pm and 1am
  FADE_END_BUFFER_MIN (optional, default 10) - minutes before 1am that the
                                last fade point lands, so it doesn't fire
                                right on top of the 1am off step
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
GROUP_SKU = "SameModeGroup"  # Govee's fixed sku for app-defined device groups

scheduler = boto3.client("scheduler")


def _group_device_id():
    return os.environ["GROUP_DEVICE_ID"]


# --------------------------------------------------------------------------
# Small HTTP helper (stdlib only, no third-party deps to package)
# --------------------------------------------------------------------------
def _http_json(method, url, headers=None, body=None, timeout=10):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    # Some APIs (e.g. sunrise-sunset.org) 403 the default Python-urllib/x.y
    # User-Agent as bot traffic, so always send something browser-like.
    req.add_header("User-Agent", "govee-sunset-scene/1.0 (+AWS Lambda)")
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
    night_k = int(os.environ.get("NIGHT_KELVIN", "2000"))
    start_b = int(os.environ.get("START_BRIGHTNESS", "60"))
    evening_b = int(os.environ.get("EVENING_BRIGHTNESS", "30"))
    end_b = int(os.environ.get("END_BRIGHTNESS", "10"))
    step_count = int(os.environ.get("STEP_COUNT", "6"))
    fade_step_count = int(os.environ.get("FADE_STEP_COUNT", "3"))
    fade_end_buffer_min = int(os.environ.get("FADE_END_BUFFER_MIN", "10"))
    group = os.environ.get("SCHEDULE_GROUP", "default")
    function_arn = os.environ["FUNCTION_ARN"]
    scheduler_role_arn = os.environ["SCHEDULER_ROLE_ARN"]

    sunset_utc = _get_sunset_utc(lat, lng, tz)
    sunset_local = sunset_utc.astimezone(tz)

    # 11pm same night, then 1am *after* tonight's sunset, in local time.
    eleven_pm_local = sunset_local.replace(hour=23, minute=0, second=0, microsecond=0)
    next_day = sunset_local.date() + timedelta(days=1)
    one_am_local = datetime(next_day.year, next_day.month, next_day.day, 1, 0, 0, tzinfo=tz)

    steps = []

    # Main ramp: sunset -> 11pm. Warms the color temp and dims brightness
    # from start_b down to evening_b. The very first step is the only one
    # that flips power from off to on, so it's the only one that needs to
    # touch power at all - it does so with one call to the "Lights" group
    # instead of one call per bulb. Every other "on" step only adjusts
    # color/brightness on the individual bulbs (power_mode="skip"), since
    # groups don't support those capabilities.
    span = (eleven_pm_local - sunset_local) / max(step_count - 1, 1)
    for i in range(step_count):
        when = sunset_local + span * i
        frac = i / max(step_count - 1, 1)
        kelvin = round(start_k + (end_k - start_k) * frac)
        brightness = round(start_b + (evening_b - start_b) * frac)
        power_mode = "group" if i == 0 else "skip"
        steps.append((when, {
            "action": "run_step", "power": "on", "colorTemp": kelvin,
            "brightness": brightness, "power_mode": power_mode,
        }))

    # Fade: 11pm -> a few minutes before 1am. Color temp keeps warming from
    # end_k down to night_k (deepest amber), while brightness keeps dimming
    # from evening_b down to end_b, right up to shutoff. The window ends
    # fade_end_buffer_min before 1am so the last fade point and the off step
    # don't land back-to-back.
    fade_window_end = one_am_local - timedelta(minutes=fade_end_buffer_min)
    fade_span = (fade_window_end - eleven_pm_local) / fade_step_count
    for i in range(1, fade_step_count + 1):
        when = eleven_pm_local + fade_span * i
        frac = i / fade_step_count
        kelvin = round(end_k + (night_k - end_k) * frac)
        brightness = round(evening_b + (end_b - evening_b) * frac)
        steps.append((when, {
            "action": "run_step", "power": "on", "colorTemp": kelvin,
            "brightness": brightness, "power_mode": "skip",
        }))

    # Off at 1am - one call to the "Lights" group instead of one per bulb.
    steps.append((one_am_local, {"action": "run_step", "power": "off", "power_mode": "group"}))

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


def _get_sunset_utc(lat, lng, tz):
    # Pass today's date explicitly, in the configured local timezone rather
    # than relying on the API's default (which is *its* server's UTC "today").
    # Without this, any invocation after ~7pm CDT (i.e. past midnight UTC)
    # would silently get tomorrow's sunset instead of tonight's.
    today_local = datetime.now(tz).date()
    try:
        resp = _http_json(
            "GET",
            f"{SUNSET_API}?lat={lat}&lng={lng}&date={today_local.isoformat()}&formatted=0",
            timeout=8,
        )
        sunset_str = resp["results"]["sunset"]  # ISO8601 UTC, e.g. 2026-08-18T01:23:45+00:00
        return datetime.fromisoformat(sunset_str)
    except Exception as e:  # noqa: BLE001 - degrade gracefully rather than doing nothing tonight
        print(f"WARNING: sunset lookup failed ({e}); falling back to 7:30pm local")
        fallback = datetime.now(tz).replace(hour=19, minute=30, second=0, microsecond=0)
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
    brightness = event.get("brightness")
    # "group"      - flip power via the Lights group (one call) instead of
    #                one call per bulb. Used only on the sunset-on and
    #                1am-off steps, where every bulb's power actually changes.
    # "skip"       - don't touch power at all (bulbs are already on/off from
    #                the group call); just adjust color/brightness per bulb.
    # "individual" - original per-bulb power behavior (default/fallback).
    power_mode = event.get("power_mode", "individual")
    device_filter = _parse_device_filter(os.environ.get("DEVICE_FILTER", ""))

    results = []

    if power_mode == "group":
        results.append(_set_power(api_key, GROUP_SKU, _group_device_id(), power == "on"))
        time.sleep(0.2)

    if power == "off":
        if power_mode == "individual":
            for d in _list_devices(api_key):
                sku, device_id = d["sku"], d["device"]
                if sku == GROUP_SKU or (device_filter and (sku, device_id) not in device_filter):
                    continue
                results.append(_set_power(api_key, sku, device_id, False))
                time.sleep(0.2)
        return {"power": power, "colorTemp": color_temp, "brightness": brightness, "devices_touched": len(results)}

    for d in _list_devices(api_key):
        sku, device_id = d["sku"], d["device"]
        if sku == GROUP_SKU or (device_filter and (sku, device_id) not in device_filter):
            continue

        caps = {c["instance"]: c for c in d.get("capabilities", [])}

        if power_mode == "individual":
            results.append(_set_power(api_key, sku, device_id, True))
            time.sleep(0.2)

        if color_temp is not None and "colorTemperatureK" in caps:
            rng = caps["colorTemperatureK"].get("parameters", {}).get("range", {})
            clamped = max(rng.get("min", 2000), min(rng.get("max", 9000), color_temp))
            results.append(_set_color_temp(api_key, sku, device_id, clamped))
            time.sleep(0.2)

        if brightness is not None and "brightness" in caps:
            rng = caps["brightness"].get("parameters", {}).get("range", {})
            clamped = max(rng.get("min", 1), min(rng.get("max", 100), brightness))
            results.append(_set_brightness(api_key, sku, device_id, clamped))
            time.sleep(0.2)

    return {"power": power, "colorTemp": color_temp, "brightness": brightness, "devices_touched": len(results)}


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


def _set_brightness(api_key, sku, device_id, percent):
    return _control(
        api_key, sku, device_id,
        {"type": "devices.capabilities.range", "instance": "brightness", "value": percent},
    )


# --------------------------------------------------------------------------
# action = "list_devices": dump sku/device id/name for every bulb the API
# key can see, e.g. to figure out GOVEE_DEVICE_FILTER pairs.
# --------------------------------------------------------------------------
def list_devices_action(event, context):
    api_key = os.environ["GOVEE_API_KEY"]
    devices = _list_devices(api_key)
    verbose = event.get("verbose", False)
    result = []
    for d in devices:
        entry = {"deviceName": d.get("deviceName"), "sku": d["sku"], "device": d["device"]}
        if verbose:
            entry["capabilities"] = [c.get("instance") for c in d.get("capabilities", [])]
        result.append(entry)
    return {"count": len(devices), "devices": result}


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
    if action == "list_devices":
        return list_devices_action(event, context)
    raise ValueError(f"Unknown action: {action!r} (expected 'plan', 'run_step', or 'list_devices')")
