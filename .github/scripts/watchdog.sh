#!/bin/bash
# watchdog.sh — نگهبان «همیشه فعال» (نسخهٔ ۲)
#   • پیام‌های سادهٔ وصل/قطع به ربات گزارش (فقط در لحظهٔ تغییر وضعیت)
#   • اگر هیچ رانی زنده نبود → خودش یکی روشن می‌کند (PAT، بعد GITHUB_TOKEN)
#   • اگر ران زنده است ولی state کهنه است → «قطع شد» با دلیل کوتاه
#   • هیچ‌وقت ران زنده را کنسل نمی‌کند
# env: REPO, STATE_REPO, STATE_TAG, STALE_MIN, VPS_NAME, TELEGRAM_BOT_TOKEN, NOTIFY_CHAT_ID,
#      SUCCESSOR_TOKEN, GITHUB_TOKEN, TEST_ALERT, TEST_DISPATCH
set -uo pipefail

REPO="${REPO:?}"
STATE_REPO="${STATE_REPO:-${REPO}-state}"
STATE_TAG="${STATE_TAG:-state}"
STALE_MIN="${STALE_MIN:-45}"
VPS_NAME="${VPS_NAME:-$(basename "$REPO")}"
MAIN_PATH=".github/workflows/main.yml"
API="https://api.github.com"
MARKER_PATH=".wd-state.json"

api() { local tok="$1"; shift
  curl -sS -m 30 -H "Authorization: Bearer ${tok}" -H "Accept: application/vnd.github+json" \
       -H "X-GitHub-Api-Version: 2022-11-28" "$@"; }

tg() {
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${NOTIFY_CHAT_ID:-}" ]; then
    echo "[watchdog] WARN: no telegram token/chat — message not sent"; return 0
  fi
  if curl -fsS -m 20 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
       -d "chat_id=${NOTIFY_CHAT_ID}" -d "disable_web_page_preview=true" \
       --data-urlencode "text=$1" >/dev/null 2>&1; then
    echo "[watchdog] telegram sent"
  else
    echo "[watchdog] WARN: telegram send failed"
  fi
}

notify_state() {
  if [ "$1" = "up" ]; then
    tg "سیستم ${VPS_NAME} وصل شد ✅"
  elif [ -n "${2:-}" ]; then
    tg "سیستم ${VPS_NAME} قطع شد ❌
(${2})"
  else
    tg "سیستم ${VPS_NAME} قطع شد ❌"
  fi
}

M_SHA=""
marker_read() {
  local r
  r="$(api "${GITHUB_TOKEN:-}" "${API}/repos/${REPO}/contents/${MARKER_PATH}?ref=main" 2>/dev/null)"
  M_SHA="$(printf '%s' "$r" | jq -r '.sha // ""' 2>/dev/null)"
  printf '%s' "$r" | jq -r '.content // ""' 2>/dev/null | tr -d '\n' | base64 -d 2>/dev/null | jq -r '.state // ""' 2>/dev/null
}
marker_write() {
  M_SHA="$M_SHA" python3 - "$1" >/tmp/wd-body.json <<'PY'
import base64, json, os, sys, time
st = sys.argv[1]
raw = json.dumps({"state": st, "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}).encode()
body = {"message": "watchdog: state=" + st, "content": base64.b64encode(raw).decode(), "branch": "main"}
if os.environ.get("M_SHA"):
    body["sha"] = os.environ["M_SHA"]
print(json.dumps(body))
PY
  local code
  code="$(api "${GITHUB_TOKEN:-}" -o /tmp/wd-put.json -w '%{http_code}' -X PUT \
      -H 'Content-Type: application/json' -d @/tmp/wd-body.json "${API}/repos/${REPO}/contents/${MARKER_PATH}")"
  case "$code" in 200|201) echo "[watchdog] marker saved ($1)";; *) echo "[watchdog] WARN: marker write http=${code}";; esac
}

TOK="${SUCCESSOR_TOKEN:-${GITHUB_TOKEN:-}}"
if [ -z "$TOK" ]; then
  tg "سیستم ${VPS_NAME} قطع شد ❌
(هیچ توکنی برای روشن‌کردن در دسترس نیست)"; exit 1
fi
echo "[watchdog] $(date -u +%FT%TZ) vps=${VPS_NAME} token=$([ -n "${SUCCESSOR_TOKEN:-}" ] && echo pat || echo github_token)"

if [ "${TEST_ALERT:-false}" = "true" ]; then
  tg "🧪 پیام تستی — سیستم ${VPS_NAME}: کانال گزارش سالم است ✅"
fi

RUNS="$(api "$TOK" "${API}/repos/${REPO}/actions/runs?per_page=50")"
live=$(printf '%s' "$RUNS" | jq -r --arg p "$MAIN_PATH" '[.workflow_runs[] | select(.path==$p)
        | select(.status=="in_progress" or .status=="queued" or .status=="waiting"
                 or .status=="requested" or .status=="pending")] | length' 2>/dev/null); live="${live:-0}"
live_id=$(printf '%s' "$RUNS" | jq -r --arg p "$MAIN_PATH" '[.workflow_runs[] | select(.path==$p)
        | select(.status=="in_progress" or .status=="queued")] | .[0].id // ""' 2>/dev/null)

stcode=$(api "$TOK" -o /tmp/st.json -w '%{http_code}' "${API}/repos/${STATE_REPO}/releases/tags/${STATE_TAG}" 2>/dev/null); stcode="${stcode:-000}"
last=$(jq -r '[.assets[].updated_at] | max // "none"' /tmp/st.json 2>/dev/null); [ -n "$last" ] || last=none
age_min=-1
[ "$last" != "none" ] && age_min=$(( ( $(date -u +%s) - $(date -u -d "$last" +%s 2>/dev/null || echo 0) ) / 60 ))
echo "[watchdog] live=${live} live_id=${live_id} state_http=${stcode} last_state=${last} age_min=${age_min}"

STATE=up; REASON=""
if [ "$stcode" = "401" ] || [ "$stcode" = "403" ]; then
  STATE=down; REASON="توکن state از کار افتاده (http=${stcode})"
elif [ "$live" -gt 0 ]; then
  if [ "$age_min" -ge 0 ] && [ "$age_min" -gt "$STALE_MIN" ]; then
    STATE=down; REASON="state ${age_min} دقیقه است آپلود نشده"
  fi
else
  STATE=down; REASON="رانی زنده نبود؛ خودکار روشن شد"
  code=$(api "$TOK" -X POST -o /tmp/resp.json -w '%{http_code}' -d '{"ref":"main"}' \
         "${API}/repos/${REPO}/actions/workflows/main.yml/dispatches")
  used=$([ "$TOK" = "${GITHUB_TOKEN:-}" ] && echo github_token || echo pat)
  if [ "$code" != "204" ] && [ -n "${GITHUB_TOKEN:-}" ] && [ "$TOK" != "${GITHUB_TOKEN}" ]; then
    echo "[watchdog] dispatch via ${used} failed (http=${code}) → retry with GITHUB_TOKEN"
    code=$(api "$GITHUB_TOKEN" -X POST -o /tmp/resp.json -w '%{http_code}' -d '{"ref":"main"}' \
           "${API}/repos/${REPO}/actions/workflows/main.yml/dispatches"); used=github_token
  fi
  echo "[watchdog] nothing live → dispatched main.yml via ${used} (http=${code})"
  if [ "$code" != "204" ]; then
    tg "سیستم ${VPS_NAME} قطع شد ❌
(روشن‌کردن خودکار هم نشد: http=${code})"; exit 1
  fi
fi

if [ "${TEST_DISPATCH:-false}" = "true" ]; then
  tcode=$(api "${GITHUB_TOKEN}" -X POST -o /tmp/td.json -w '%{http_code}' -d '{"ref":"main"}' \
          "${API}/repos/${REPO}/actions/workflows/main.yml/dispatches")
  echo "[watchdog] test_dispatch http=${tcode}"
fi

prev="$(marker_read)"
if [ "$STATE" != "$prev" ]; then
  notify_state "$STATE" "$REASON"
  marker_write "$STATE"
else
  echo "[watchdog] no change (${STATE}) — no message"
fi
exit 0
