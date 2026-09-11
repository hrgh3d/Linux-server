#!/bin/bash
# watchdog.sh — منطق نگهبان «همیشه فعال» (هم توسط watchdog.yml و هم watchdog-b.yml اجرا می‌شود).
#   ۱) اگر هیچ رانی از main.yml زنده/در صف نبود → خودش یکی روشن می‌کند.
#   ۲) اگر رانی زنده است ولی state بیش از STALE_MIN دقیقه آپلود نشده → هشدار تلگرام.
#   ۳) اگر dispatch شکست بخورد → هشدار تلگرام با متن دقیق.
# هیچ‌وقت ران زنده را کنسل نمی‌کند (هندآف جانشین دست‌نخورده می‌ماند).
#
# env ورودی: REPO, STATE_REPO, STATE_TAG, STALE_MIN, TELEGRAM_BOT_TOKEN, NOTIFY_CHAT_ID,
#            SUCCESSOR_TOKEN (اختیاری), GITHUB_TOKEN (همیشه موجود), TEST_ALERT, TEST_DISPATCH
set -uo pipefail

REPO="${REPO:?}"
STATE_REPO="${STATE_REPO:-${REPO}-state}"
STATE_TAG="${STATE_TAG:-state}"
STALE_MIN="${STALE_MIN:-45}"
MAIN_PATH=".github/workflows/main.yml"

api() {  # api <token> <curl args...>
  local tok="$1"; shift
  curl -sS -m 30 -H "Authorization: Bearer ${tok}" -H "Accept: application/vnd.github+json" \
       -H "X-GitHub-Api-Version: 2022-11-28" "$@"
}

alert() {
  local msg="$1"
  echo "[watchdog] ALERT: ${msg}"
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${NOTIFY_CHAT_ID:-}" ]; then
    if curl -fsS -m 20 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
         -d "chat_id=${NOTIFY_CHAT_ID}" -d "disable_web_page_preview=true" \
         --data-urlencode "text=🔴 Linux-server watchdog: ${msg}" >/dev/null 2>&1; then
      echo "[watchdog] alert delivered via telegram"
    else
      echo "[watchdog] WARN: telegram alert failed"
    fi
  else
    echo "[watchdog] WARN: no telegram token/chat configured — alert not delivered"
  fi
  return 0
}

# ترتیب توکن: PAT → GITHUB_TOKEN (هر دو تست‌شده و کار می‌کنند)
TOK="${SUCCESSOR_TOKEN:-${GITHUB_TOKEN:-}}"
if [ -z "$TOK" ]; then alert "no token available for dispatch — cannot guarantee uptime"; exit 1; fi
echo "[watchdog] $(date -u +%FT%TZ) token=$([ -n "${SUCCESSOR_TOKEN:-}" ] && echo pat || echo github_token)"

if [ "${TEST_ALERT:-false}" = "true" ]; then
  alert "تست کانال هشدار (درخواستی) — همه‌چیز مرتب است."
fi

RUNS="$(api "$TOK" "https://api.github.com/repos/${REPO}/actions/runs?per_page=50")"
live=$(printf '%s' "$RUNS" | jq -r --arg p "$MAIN_PATH" '[.workflow_runs[] | select(.path==$p)
        | select(.status=="in_progress" or .status=="queued" or .status=="waiting"
                 or .status=="requested" or .status=="pending")] | length' 2>/dev/null)
live_id=$(printf '%s' "$RUNS" | jq -r --arg p "$MAIN_PATH" '[.workflow_runs[] | select(.path==$p)
        | select(.status=="in_progress" or .status=="queued")] | .[0].id // ""' 2>/dev/null)
live="${live:-0}"

last=$(api "$TOK" "https://api.github.com/repos/${STATE_REPO}/releases/tags/${STATE_TAG}" 2>/dev/null \
       | jq -r '.assets[0].updated_at // "none"' 2>/dev/null)
age_min=-1
if [ -n "$last" ] && [ "$last" != "none" ]; then
  age_min=$(( ( $(date -u +%s) - $(date -u -d "$last" +%s 2>/dev/null || echo 0) ) / 60 ))
fi
echo "[watchdog] live=${live} live_id=${live_id} last_state=${last} age_min=${age_min}"

if [ "$live" -gt 0 ]; then
  if [ "$age_min" -ge 0 ] && [ "$age_min" -gt "$STALE_MIN" ]; then
    alert "ران ${live_id} زنده است ولی ${age_min} دقیقه است state آپلود نشده (سقف ${STALE_MIN} دقیقه) — saveها شکست می‌خورند. احتمالاً PERSIST_TOKEN منقضی/باطل شده؛ تا تعویض نشود، سرور بعد از پایان این ران بدون state تازه بالا می‌آید."
  else
    echo "[watchdog] healthy — nothing to do"
  fi
  if [ "${TEST_DISPATCH:-false}" = "true" ]; then
    code=$(api "${GITHUB_TOKEN}" -X POST -o /tmp/td.json -w '%{http_code}' -d '{"ref":"main"}' \
           "https://api.github.com/repos/${REPO}/actions/workflows/ops-server-check.yml/dispatches")
    echo "[watchdog] test_dispatch via GITHUB_TOKEN http=${code}"
    [ "$code" = "204" ] || head -c 200 /tmp/td.json
  fi
  exit 0
fi

code=$(api "$TOK" -X POST -o /tmp/resp.json -w '%{http_code}' -d '{"ref":"main"}' \
       "https://api.github.com/repos/${REPO}/actions/workflows/main.yml/dispatches")
echo "[watchdog] nothing live → dispatched main.yml (http=${code})"
if [ "$code" != "204" ]; then
  alert "هیچ رانی زنده نبود و dispatch هم شکست خورد (http=${code}). سرور خاموش است و خودکار بالا نمی‌آید. پاسخ: $(head -c 200 /tmp/resp.json 2>/dev/null)"
  exit 1
fi
echo "[watchdog] recovered — a fresh run was dispatched"
