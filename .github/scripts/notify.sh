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
# v6.13: ربات گزارش (REPORT_BOT_TOKEN) از ربات Hermes Gateway جداست — هشدارها
# اولویت با REPORT_BOT_TOKEN دارند تا کانال Hermes اشغال/مخلوط نشود.
#
# v6.36: اگر توکن در محیط نبود (مثلاً save.sh آن را موقتاً blank کرده یا اسکریپت
# خارج از workflow اجرا شده)، از همان منابع روی دیسک می‌خوانیم تا هشدار
# «ذخیره‌سازی خراب است» هرگز به‌خاطر نبودِ توکن گم نشود.
_ALERT_TG_TOKEN="${REPORT_BOT_TOKEN:-${TELEGRAM_BOT_TOKEN:-}}"
if [ -z "${_ALERT_TG_TOKEN}" ]; then
  for _src in /run/report-bot.token /root/.hermes/.report-bot.token; do
    [ -s "$_src" ] && _ALERT_TG_TOKEN="$(tr -d '\r\n' < "$_src")" && break
  done
fi
if [ -z "${_ALERT_TG_TOKEN}" ] && [ -r /root/.hermes/.env ]; then
  _ALERT_TG_TOKEN="$(grep -m1 '^REPORT_BOT_TOKEN=.\{8,\}' /root/.hermes/.env 2>/dev/null | cut -d= -f2-)"
fi
if [ -z "${_ALERT_TG_TOKEN}" ]; then
  _PRE="$(ls -1t /root/.hermes/.env.pre-guard.* /var/lib/hermes-guard/env.preblank 2>/dev/null | head -1)"
  [ -n "$_PRE" ] && _ALERT_TG_TOKEN="$(grep -m1 '^REPORT_BOT_TOKEN=.\{8,\}' "$_PRE" 2>/dev/null | cut -d= -f2-)"
fi
_ALERT_CHAT="${NOTIFY_CHAT_ID:-}"
[ -n "$_ALERT_CHAT" ] || _ALERT_CHAT="$(grep -m1 '^NOTIFY_CHAT_ID=' /root/.hermes/.env 2>/dev/null | cut -d= -f2-)"
[ -n "$_ALERT_CHAT" ] || _ALERT_CHAT="7262486406"
NOTIFY_CHAT_ID="$_ALERT_CHAT"

_TG_SENT=0
if [ -z "${NOTIFY_WEBHOOK_URL:-}" ] && [ -n "${_ALERT_TG_TOKEN}" ] && [ -n "${NOTIFY_CHAT_ID:-}" ]; then
  _MSG="سیستم ${VPS_NAME:-hrgh3d} قطع شد ❌
مرحله: ${STAGE} (run ${RUN}#${ATT})
$(printf '%s' "${ERR}" | head -c 300)"
  if curl -fsS -m 20 -X POST "https://api.telegram.org/bot${_ALERT_TG_TOKEN}/sendMessage" \
       -d "chat_id=${NOTIFY_CHAT_ID}" -d "disable_web_page_preview=true" \
       --data-urlencode "text=${_MSG}" >/dev/null 2>&1; then
    echo "[notify] telegram alert sent (direct, no webhook)"
    _TG_SENT=1
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
elif [ "$_TG_SENT" -eq 1 ]; then
  # v6.36: قبلاً اینجا بی‌قید چاپ می‌شد «هیچ اعلانی ارسال نشد» — حتی وقتی
  # تلگرام موفق بوده. آن پیام غلط، تحلیل حادثهٔ 2026-09-17 را گمراه کرد.
  echo "[notify] delivered via direct telegram (no webhook configured — that is fine)"
else
  echo "[notify] WARN: alert NOT delivered — no webhook and no usable telegram token/chat"
  echo "        (GitHub failure email/notification will also fire if the job fails)"
fi
exit 0
