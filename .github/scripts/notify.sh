#!/bin/bash
# ============================================================================
# notify.sh — ثبت و ارسال اعلان «Failure» برای چرخه‌های Backup/Restore/Server.
#
#   - همیشه یک نشانگر JSON در /tmp/failure-notify.json ثبت می‌کند (قدم پایانی
#     workflow آن را می‌خواند تا حتی اگر job در همان قدمِ خطا متوقف شد، اعلان
#     از دست نرود).
#   - خروجی را به GITHUB_STEP_SUMMARY (در صورت موجود بودن) اضافه می‌کند.
#   - v6.47: ارسال فقط از راه report.sh و فقط به ربات گزارش انجام می‌شود.
#     پشتیبانی از NOTIFY_WEBHOOK_URL و fallback به ربات Hermes حذف شد تا
#     هیچ گزارشی به مقصد دیگری نرود.
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

# --- delivery: ONE destination only (v6.47) ---------------------------------
# قبلاً اینجا دو راه فرار وجود داشت که گزارش را به مقصد دیگری می‌برد:
#   1) fallback به TELEGRAM_BOT_TOKEN (ربات گفتگوی Hermes)
#   2) NOTIFY_WEBHOOK_URL که می‌توانست Discord یا هر URL دلخواه باشد
# طبق درخواست کاربر «فقط ربات آخر، نه هیچ جای دیگر» هر دو حذف شدند.
# تنها مسیر مجاز: report.sh → REPORT_BOT_TOKEN + NOTIFY_CHAT_ID.
_MSG="سیستم ${VPS_NAME:-hrgh3d} قطع شد ❌
مرحله: ${STAGE} (run ${RUN}#${ATT})
$(printf '%s' "${ERR}" | head -c 300)"

_RPT=""
for _c in "${GITHUB_WORKSPACE:-}/.github/scripts/report.sh" /usr/local/bin/report.sh \
          "$(dirname "${BASH_SOURCE[0]}")/report.sh"; do
  [ -x "$_c" ] && _RPT="$_c" && break
done

if [ -n "$_RPT" ] && "$_RPT" text "$_MSG"; then
  echo "[notify] alert delivered to the report bot"
else
  echo "[notify] WARN: alert NOT delivered (report.sh missing or destination down)"
  echo "        (GitHub failure notification for this job will still fire)"
fi
exit 0
