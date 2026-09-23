#!/bin/bash
# notify_test.sh (v6.47) — تست کانال گزارش.
# قبلاً از TELEGRAM_BOT_TOKEN (ربات گفتگوی Hermes) استفاده می‌کرد؛ حالا دقیقاً
# همان مسیری را تست می‌کند که گزارش‌های واقعی از آن می‌روند: report.sh → ربات گزارش.
set -u
RPT=""
for c in /usr/local/bin/report.sh \
         "${GITHUB_WORKSPACE:-}/.github/scripts/report.sh" \
         "$(dirname "${BASH_SOURCE[0]}")/report.sh"; do
  [ -x "$c" ] && RPT="$c" && break
done
if [ -z "$RPT" ]; then echo "RESULT: NO_REPORT_GATEWAY"; exit 0; fi

if ! "$RPT" check; then echo "RESULT: DESTINATION_UNREACHABLE"; exit 0; fi

if "$RPT" text "✅ تست کانال گزارش Linux-server — از این پس همهٔ گزارش‌ها، هشدارها، تغییر آدرس داشبوردها و بکاپ‌ها فقط به همین ربات می‌آید."; then
  echo "send: ok=True"
else
  echo "send: ok=False"
fi
echo "DONE"
