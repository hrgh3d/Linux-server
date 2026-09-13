#!/usr/bin/env python3
# ============================================================================
# heartbeat.py — ضربان‌سبک روی Release «state» (v6.13)
#
# مشکل: save.sh با dedup sha256 کار می‌کند؛ اگر سرور idle باشد هیچ asset جدید
# آپلود نمی‌شود و watchdog بعد از STALE_MIN دقیقه «قطع شد» کاذب می‌فرستد
# (در حالی‌که سرور زنده است و save سالم کار می‌کند — فقط تغییر ندارد).
#
# راه‌حل: هر چرخه‌ی auto-sync یک asset کوچک «heartbeat-<UTC>.txt» روی همان
# Release جای‌گذاری می‌شود (قبلی‌ها پاک می‌شوند). watchdog همان
# max(assets[].updated_at) را می‌خواند → تازگی heartbeat = اثبات زنده بودن
# «مسیر ذخیره» (توکن + API + runner). اگر توکن بمیرد، heartbeat هم 401
# می‌گیرد و state کهنه می‌شود → هشدار واقعی همچنان کار می‌کند.
#
# assetهای heartbeat هیچ‌وقت با state-*.tar.gz اشتباه گرفته نمی‌شوند:
#   - restore فقط state-*.tar.gz را انتخاب می‌کند (state_sync._asset_is_state)
#   - purge در state_sync هم فقط state-*.tar.gz را حذف می‌کند
#
# env: PERSIST_TOKEN (یا GH_TOKEN/GITHUB_TOKEN), PERSIST_REPO, STATE_TAG
# خروجی: یک خط لاگ؛ هرگز non-zero خارج نمی‌شود (غیرکشنده برای keepalive).
# ============================================================================
import json
import os
import sys
import time
import urllib.error
import urllib.request

API = "https://api.github.com"


def log(msg):
    print("[heartbeat] %s" % msg, flush=True)


def req(method, path, token, body=None, headers=None, raw=None):
    h = {
        "Authorization": "Bearer %s" % token,
        "Accept": "application/vnd.github+json",
        "User-Agent": "linux-server-heartbeat",
    }
    if headers:
        h.update(headers)
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        h["Content-Type"] = "application/json"
    if raw is not None:
        data = raw
    r = urllib.request.Request(API + path, method=method, data=data, headers=h)
    with urllib.request.urlopen(r, timeout=30) as resp:
        payload = resp.read()
        return resp.status, (payload if payload else b"")


def main():
    token = (os.environ.get("PERSIST_TOKEN") or os.environ.get("GH_TOKEN")
             or os.environ.get("GITHUB_TOKEN") or "")
    repo = os.environ.get("PERSIST_REPO", "")
    tag = os.environ.get("STATE_TAG", "state")
    if not token or not repo:
        log("no token/repo — skipped")
        return
    try:
        st, body = req("GET", "/repos/%s/releases/tags/%s" % (repo, tag), token)
        rel = json.loads(body)
    except urllib.error.HTTPError as e:
        log("release lookup failed HTTP %d — skipped (non-fatal)" % e.code)
        return
    except Exception as e:
        log("release lookup error: %s — skipped (non-fatal)" % e)
        return
    rel_id = rel.get("id")
    if not rel_id:
        log("release id missing — skipped")
        return

    # 1) حذف heartbeat های قدیمی (فقط نام‌های heartbeat*؛ به state-*.tar.gz دست نمی‌زند)
    for a in rel.get("assets", []):
        name = a.get("name", "")
        if name.startswith("heartbeat"):
            try:
                req("DELETE", "/repos/%s/releases/assets/%d" % (repo, a["id"]), token)
            except Exception as e:
                log("WARN delete old %s: %s" % (name, e))

    # 2) آپلود heartbeat تازه
    ts = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    content = ("ts=%s\nrun=%s\nattempt=%s\nboot=%s\n" % (
        time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        os.environ.get("GITHUB_RUN_ID", "?"),
        os.environ.get("GITHUB_RUN_ATTEMPT", "?"),
        os.environ.get("BOOT_TS", "?"))).encode()
    try:
        st, _ = req(
            "POST",
            "/repos/%s/releases/%d/assets?name=heartbeat-%s.txt" % (repo, rel_id, ts),
            token,
            headers={"Content-Type": "text/plain"},
            raw=content,
        )
        log("ok (HTTP %d, heartbeat-%s.txt)" % (st, ts))
    except urllib.error.HTTPError as e:
        log("upload failed HTTP %d — save pipeline may be broken (non-fatal here)" % e.code)
    except Exception as e:
        log("upload error: %s (non-fatal)" % e)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # هرگز keepalive را نکُش
        log("unexpected error (non-fatal): %s" % e)
    sys.exit(0)
