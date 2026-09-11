#!/bin/bash
# ============================================================================
# notify.sh — ثبت و ارسال اعلان «Failure» برای چرخه‌های Backup/Restore/Server.
#
#   - همیشه یک نشانگر JSON در /tmp/failure-notify.json ثبت می‌کند (قدم پایانی
#     workflow آن را می‌خواند تا حتی اگر job در همان قدمِ خطا متوقف شد، اعلان
#     از دست نرود).
#   - خروجی را به GITHUB_STEP_SUMMARY (در صورت موجود بودن) اضافه می‌کند.
#   - اگر NOTIFY_WEBHOOK_URL تنظیم شده باشد، اعلان می‌فرستد؛ فرمت خودکار:
#     Discord webhook URL => {"content": ...} ؛ Telegram bot URL => {"text": ...}
#     (برای تلگرام، chat_id را در خود URL بگذار: .../sendMessage?chat_id=<ID>)
#     بقیه URLها => همان JSON خام قبلی.
#     (وب‌هوک اختیاری است؛ بدون آن، GitHub notification خود workflow برای
#     job شکست‌خورده + گزارش همین قدم در دسترس است.)
#
# Usage: notify.sh --type <backup|restore|server|workflow> \
#                  --stage <نام مرحله> \
#                  --error <متن خطا تا آخر>
# ============================================================================
set -uo pipefail

TYPE="unknown"
STAGE="unknown"
ERR=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --type)  TYPE="${2:-unknown}"; shift 2 ;;
    --stage) STAGE="${2:-unknown}"; shift 2 ;;
    --error) shift; ERR="$*"; break ;;
    *) shift ;;
  esac
done
[ -n "$ERR" ] || ERR="(no error text provided)"

RUN="${GITHUB_RUN_ID:-?}"
ATT="${GITHUB_RUN_ATTEMPT:-1}"
TS="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# --- marker for the final workflow step ------------------------------------
python3 - "$TYPE" "$STAGE" "$ERR" "$RUN" "$ATT" "$TS" <<'PY'
import json, os, sys
t, s, e, r, a, ts = sys.argv[1:7]
path = "/tmp/failure-notify.json"
try:
    obj = json.load(open(path))
except Exception:
    obj = {"run": r, "attempt": a}
obj.setdefault("events", []).append(
    {"type": t, "stage": s, "error": e, "run": r, "attempt": a, "ts": ts})
with open(path, "w") as fh:
    json.dump(obj, fh, indent=2)
PY

echo "[notify] FAILURE type=${TYPE} stage=${STAGE} run=${RUN}#${ATT} ts=${TS}"
echo "[notify] error: ${ERR}"

# --- step summary -----------------------------------------------------------
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo ""
    echo "## ❌ Linux-server failure"
    echo ""
    echo "| Item | Value |"
    echo "|---|---|"
    echo "| Operation | \`${TYPE}\` |"
    echo "| Stage | \`${STAGE}\` |"
    echo "| Run | \`${RUN}\` (attempt ${ATT}) |"
    echo "| Time | \`${TS}\` |"
    echo ""
    echo '```'
    echo "${ERR}"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
fi

# --- direct Telegram (no webhook needed) -------------------------------------
# اگر وبهوک ست نشده باشد ولی توکن ربات و chat_id موجود باشند، مستقیم به تلگرام می‌فرستد.
if [ -z "${NOTIFY_WEBHOOK_URL:-}" ] && [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${NOTIFY_CHAT_ID:-}" ]; then
  _MSG="سیستم ${VPS_NAME:-hrgh3d} قطع شد ❌
مرحله: ${STAGE} (run ${RUN}#${ATT})
$(printf '%s' "${ERR}" | head -c 300)"
  if curl -fsS -m 20 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
       -d "chat_id=${NOTIFY_CHAT_ID}" -d "disable_web_page_preview=true" \
       --data-urlencode "text=${_MSG}" >/dev/null 2>&1; then
    echo "[notify] telegram alert sent (direct, no webhook)"
  else
    echo "[notify] WARN: telegram direct send failed"
  fi
fi

# --- optional webhook --------------------------------------------------------
if [ -n "${NOTIFY_WEBHOOK_URL:-}" ]; then
  _MSG="سیستم ${VPS_NAME:-hrgh3d} قطع شد ❌ — مرحله ${STAGE} (run ${RUN}#${ATT}): $(printf '%s' "${ERR}" | head -c 300)"
  case "${NOTIFY_WEBHOOK_URL}" in
    *discord.com/api/webhooks*)
      PAYLOAD="$(python3 -c 'import json,sys; print(json.dumps({"content": sys.argv[1][:1800]}))' "$_MSG")" ;;
    *api.telegram.org*)
      PAYLOAD="$(python3 -c 'import json,sys; print(json.dumps({"text": sys.argv[1][:3500]}))' "$_MSG")" ;;
    *)
      PAYLOAD="$(python3 - "$TYPE" "$STAGE" "$ERR" "$RUN" "$ATT" "$TS" <<'PY'
import json, sys
print(json.dumps({
    "type": sys.argv[1], "stage": sys.argv[2], "error": sys.argv[3],
    "run_id": sys.argv[4], "attempt": sys.argv[5], "time": sys.argv[6],
    "message": f"Linux-server {sys.argv[1]} failure at {sys.argv[2]} "
               f"(run {sys.argv[4]}#{sys.argv[5]})",
}))
PY
)" ;;
  esac
  if ! curl -fsS -m 20 -H 'Content-Type: application/json' \
      -d "$PAYLOAD" "$NOTIFY_WEBHOOK_URL" >/dev/null 2>&1; then
    echo "[notify] WARN: webhook send failed (URL not reachable/rejected)"
  else
    echo "[notify] webhook notification sent"
  fi
else
  echo "[notify] no NOTIFY_WEBHOOK_URL and no direct telegram (TELEGRAM_BOT_TOKEN+NOTIFY_CHAT_ID) — notification recorded locally "
  echo "        (GitHub failure email/notification will also fire if the job fails)"
fi
exit 0
