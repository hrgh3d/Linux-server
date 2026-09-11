#!/bin/bash
# notify_setup.sh — روی سرور اجرا می‌شود: توکن ربات تلگرام را از /root/.hermes/.env می‌خواند،
# ربات را با getMe چک می‌کند، چت‌های شناخته‌شده را از getUpdates درمی‌آورد و یک پیام تست می‌فرستد.
# خود توکن هرگز چاپ نمی‌شود (فقط طول)، ولی chat_id چاپ می‌شود (راز نیست).
set -u
ADMIN_ID="${ADMIN_ID:-7262486406}"
ENVF=/root/.hermes/.env
TOK=""
for f in "$ENVF" /root/.hermes/*.env /opt/hermes/.env; do
  [ -f "$f" ] || continue
  T="$(grep -m1 '^TELEGRAM_BOT_TOKEN=' "$f" 2>/dev/null | cut -d= -f2- | tr -d '"'\'' \r')"
  if [ -n "${T:-}" ]; then TOK="$T"; echo "token file: $f"; break; fi
done
if [ -z "${TOK:-}" ]; then echo "RESULT: NO_TOKEN_FOUND"; exit 0; fi
echo "token_len: ${#TOK}"
ME="$(curl -s -m 20 "https://api.telegram.org/bot${TOK}/getMe")"
echo "getMe: $(printf '%s' "$ME" | python3 -c 'import sys,json;d=json.load(sys.stdin);r=d.get("result") or {};print("ok=%s username=%s id=%s"%(d.get("ok"),r.get("username"),r.get("id")))' 2>/dev/null)"
WH="$(curl -s -m 20 "https://api.telegram.org/bot${TOK}/getWebhookInfo")"
echo "webhook: $(printf '%s' "$WH" | python3 -c 'import sys,json;d=json.load(sys.stdin);r=d.get("result") or {};print("set=%s pending=%s"%(bool(r.get("url")),r.get("pending_update_count")))' 2>/dev/null)"
UPD="$(curl -s -m 20 "https://api.telegram.org/bot${TOK}/getUpdates?limit=30")"
DISCOVERED="$(printf '%s' "$UPD" | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception: print(""); raise SystemExit
ids=set()
for u in (d.get("result") or []):
    m=u.get("message") or u.get("edited_message") or u.get("callback_query") or {}
    c=(m.get("chat") or {}).get("id") or ((m.get("message") or {}).get("chat") or {}).get("id")
    if c: ids.add(str(c))
print(" ".join(sorted(ids)))' 2>/dev/null)"
echo "discovered_chat_ids: ${DISCOVERED:-none}"
SEEN=""
for CID in $ADMIN_ID $DISCOVERED; do
  case " $SEEN " in *" $CID "*) continue;; esac
  SEEN="$SEEN $CID"
  R="$(curl -s -m 20 -X POST "https://api.telegram.org/bot${TOK}/sendMessage" \
       -d "chat_id=${CID}" --data-urlencode "text=🔔 تست اعلان‌های سیستمی Linux-server — اگر این پیام را می‌بینی، مسیر هشدار سالم است.")"
  echo "send ${CID}: $(printf '%s' "$R" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("ok=%s %s"%(d.get("ok"),(d.get("description") or "")[:70]))' 2>/dev/null)"
done
echo "DONE"
