#!/bin/bash
# notify_test.sh — روی سرور: توکن ربات را می‌خواند و یک پیام تست به آیدی ادمین می‌فرستد.
# هیچ مقدار حساسی چاپ نمی‌شود؛ فقط ok/error و «آیا آیدی با 7262486406 یکی است؟».
set -u
ADMIN_ID="${ADMIN_ID:-7262486406}"
ENVF=/root/.hermes/.env
TOK="$(awk -F'=' '/^[[:space:]]*TELEGRAM_BOT_TOKEN=/{v=$0; sub(/^[^=]*=/,"",v); gsub(/[\r"'"'"']/,"",v); if (length(v)>20){print v; exit}}' "$ENVF" 2>/dev/null)"
if [ -z "${TOK:-}" ]; then echo "RESULT: NO_TOKEN"; exit 0; fi
echo "token_len: ${#TOK}"
ALLOWED="$(awk -F'=' '/^[[:space:]]*TELEGRAM_ALLOWED_USERS=/{v=$0; sub(/^[^=]*=/,"",v); gsub(/[\r"'"'"' ]/,"",v); if (length(v)>4){print v; exit}}' "$ENVF" 2>/dev/null | cut -d, -f1)"
if [ "${ALLOWED:-}" = "$ADMIN_ID" ]; then echo "allowed_users matches ADMIN_ID: yes"; else echo "allowed_users matches ADMIN_ID: no (len=${#ALLOWED})"; fi
R="$(curl -s -m 20 -X POST "https://api.telegram.org/bot${TOK}/sendMessage" \
     -d "chat_id=${ADMIN_ID}" -d "disable_web_page_preview=true" \
     --data-urlencode "text=✅ تست کانال هشدار Linux-server — از این پس اگر state آپلود نشود یا سرور خاموش شود، همین‌جا پیام می‌گیری.")"
echo "send: $(printf '%s' "$R" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("ok=%s %s"%(d.get("ok"),(d.get("description") or "")[:70]))' 2>/dev/null)"
echo "DONE"
