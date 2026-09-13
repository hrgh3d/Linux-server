#!/bin/bash
# ============================================================================
# tunnel-run.sh (v6.14) — اجرای عمومی یک تونل quick cloudflared
#   usage: tunnel-run.sh <name> <target-url> <url-file>
# آدرس trycloudflare را استخراج و در <url-file> می‌نویسد؛ اعلام عمومی آدرس
# وظیفه‌ی tunnel-watch.sh است (تنها از راه «ربات گزارش سیستم»).
# ============================================================================
set -u
NAME="${1:?name required}"; TARGET="${2:?target required}"; URLFILE="${3:?urlfile required}"
LOG="/var/log/tunnel-${NAME}.log"
: > "$LOG"
cloudflared tunnel --no-autoupdate --url "$TARGET" >>"$LOG" 2>&1 &
CPID=$!
URL=""
for i in $(seq 1 45); do
  URL=$(grep -oE "https://[a-z0-9-]+\.trycloudflare\.com" "$LOG" 2>/dev/null | head -1)
  [ -n "$URL" ] && break
  kill -0 $CPID 2>/dev/null || { echo "[tunnel-$NAME] cloudflared died early"; sleep 8; exit 1; }
  sleep 2
done
if [ -z "$URL" ]; then echo "[tunnel-$NAME] no URL after 90s"; exit 1; fi
echo "$URL" > "$URLFILE"
echo "[tunnel-$NAME] URL: $URL (target $TARGET)"
wait $CPID
