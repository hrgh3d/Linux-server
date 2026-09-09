#!/usr/bin/env python3
# ============================================================================
# tailscale_expiry_check.py — هشدار انقضای کلیدهای Tailscale (v5.4)
#
# در هر بوت یک‌بار اجرا می‌شود و انقضای این‌ها را بررسی می‌کند:
#   ۱) node key همین دستگاه (devices API: keyExpiryDisabled / expires)
#   ۲) auth key تلنت (keys API؛ تطبیق با شناسه‌ی استخراج‌شده از TAILSCALE_AUTH_KEY)
# در صورت نزدیک بودن انقضا (< 10 روز) هشدار در لاگ + صفحه‌ی Summary ران ثبت
# می‌شود (از طریق notify.sh). این اسکریپت HERGEZ با خطا خارج نمی‌شود تا بوت
# را خراب نکند؛ اگر چیزی قابل خواندن نبود فقط لاگ می‌زند و رد می‌شود.
#
# env لازم: TAILSCALE_API_TOKEN (+ TS_SELF_NODEKEY و TS_AUTHKEY_ID)
# ============================================================================
import json
import os
import subprocess
import time
import urllib.request
import urllib.error
from datetime import datetime, timezone

WARN_DAYS = 10
API = "https://api.tailscale.com"


def api_get(token, path):
    req = urllib.request.Request(
        API + path, headers={"Authorization": "Bearer %s" % token})
    with urllib.request.urlopen(req, timeout=25) as r:
        return json.load(r)


def parse_rfc3339(s):
    try:
        if not s:
            return None
        return datetime.fromisoformat(str(s).replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def notify(msg):
    here = os.path.dirname(os.path.abspath(__file__))
    try:
        subprocess.run(
            ["bash", os.path.join(here, "notify.sh"),
             "--type", "server", "--stage", "key-expiry",
             "--error", msg],
            timeout=30, check=False,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception as e:
        print("[key-expiry] notify failed: %s" % e)


def main():
    token = os.environ.get("TAILSCALE_API_TOKEN", "")
    if not token or token == "NOT_SET":
        print("[key-expiry] no API token — check skipped")
        return
    nodekey = os.environ.get("TS_SELF_NODEKEY", "")
    authkey_id = os.environ.get("TS_AUTHKEY_ID", "")
    warnings = []

    # ---- 1) node key همین دستگاه ----
    try:
        devs = api_get(token, "/api/v2/tailnet/-/devices?fields=all").get("devices", [])
        me = None
        for d in devs:
            if nodekey and d.get("nodeKey") == nodekey:
                me = d
                break
        if me is None:
            print("[key-expiry] self device not found via devices API (nodeKey match failed)")
        elif me.get("keyExpiryDisabled"):
            print("[key-expiry] node key expiry DISABLED for %s — OK (never expires)"
                  % me.get("hostname"))
        else:
            exp = parse_rfc3339(me.get("expires"))
            if exp:
                days = (exp - time.time()) / 86400
                print("[key-expiry] node key expires in %.1f days (%s)"
                      % (days, me.get("expires")))
                if days < WARN_DAYS:
                    warnings.append(
                        "کلید دستگاه %s تا %.0f روز دیگر منقضی می‌شود! در کنسول: Machines ← Disable key expiry"
                        % (me.get("hostname"), days))
            else:
                warnings.append(
                    "انقضای کلید دستگاه %s فعال است (تاریخ دقیق خوانده نشد) — پیشنهاد: Disable key expiry در کنسول"
                    % me.get("hostname"))
    except Exception as e:
        print("[key-expiry] devices check skipped: %s" % e)

    # ---- 2) auth key تلنت ----
    try:
        data = api_get(token, "/api/v2/tailnet/-/keys")
        keys = data.get("keys", data) if isinstance(data, dict) else data
        if not isinstance(keys, list):
            keys = []
        mine = None
        for k in keys:
            if not isinstance(k, dict):
                continue
            kid = str(k.get("id", ""))
            if authkey_id and kid and (
                    kid == authkey_id or kid.startswith(authkey_id)
                    or authkey_id.startswith(kid)):
                mine = k
                break
        if mine is None:
            print("[key-expiry] auth key id '%s' not matched via API (%d keys listed) — check expiry in admin console manually"
                  % (authkey_id, len(keys)))
        else:
            exp = None
            for field in ("expires", "expiresAt", "expiry"):
                if mine.get(field):
                    exp = parse_rfc3339(mine[field])
                    if exp:
                        break
            if exp is None and mine.get("expirySeconds") is not None:
                try:
                    v = float(mine["expirySeconds"])
                    if v > 1e9:
                        exp = v  # epoch
                    elif mine.get("created"):
                        c = parse_rfc3339(mine["created"])
                        if c:
                            exp = c + v  # مدت‌زمان از زمان ساخت
                except Exception:
                    exp = None
            if exp:
                days = (exp - time.time()) / 86400
                print("[key-expiry] auth key expires in %.1f days" % days)
                if days < WARN_DAYS:
                    warnings.append(
                        "کلید اتصال Tailscale تا %.0f روز دیگر منقضی می‌شود! کلید تازه بساز و Secret را عوض کن"
                        % days)
            else:
                print("[key-expiry] auth key found but expiry unreadable — check admin console manually")
    except Exception as e:
        print("[key-expiry] auth-keys check skipped: %s" % e)

    # ---- 3) تاریخ‌های دستی (key-dates.json؛ برای توکن‌هایی که API انقضا ندارند) ----
    try:
        here = os.path.dirname(os.path.abspath(__file__))
        kd_path = os.path.join(here, "..", "key-dates.json")
        with open(kd_path, encoding="utf-8") as fh:
            kd = json.load(fh)
        for name, val in kd.items():
            if name == "notes" or not val or str(val).startswith("TODO"):
                continue
            try:
                exp = datetime.fromisoformat(str(val)).replace(tzinfo=timezone.utc).timestamp()
            except Exception:
                print("[key-expiry] key-dates: unreadable date for %s: %r" % (name, val))
                continue
            days = (exp - time.time()) / 86400
            print("[key-expiry] key-dates: %s expires in %.1f days" % (name, days))
            if days < WARN_DAYS:
                warnings.append("تاریخ انقضای %s نزدیک است (%.0f روز)! عوضش کن و key-dates.json را به‌روز کن" % (name, days))
    except FileNotFoundError:
        print("[key-expiry] key-dates.json not found — skipping manual dates")
    except Exception as e:
        print("[key-expiry] key-dates check skipped: %s" % e)

    for w in warnings:
        print("[key-expiry] WARNING: %s" % w)
        notify(w)
    if not warnings:
        print("[key-expiry] all key checks done — no warning")


try:
    main()
except Exception as e:
    print("[key-expiry] unexpected error (non-fatal): %s" % e)
