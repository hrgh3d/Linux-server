#!/bin/bash
# ============================================================================
# tunnel-watch.sh (v6.15) — نگهبان تونل‌های داشبورد (Hermes + 9router)
#
#   * هر ۳۰ ثانیه: وضعیت یونیت‌های تونل + آدرس فعلی هر تونل را می‌خواند.
#   * اگر یونیتی مرده باشد → ری‌استارت (cloudflared quick tunnel آدرس تازه
#     می‌گیرد)؛ اگر آدرسی «به هر دلیلی» عوض شود (ری‌استارت، ریبیلد رانر،
#     قطعی cloudflare) → آدرس جدید **فقط از راه ربات گزارش سیستم**
#     قالب v6.15 (دقیقاً طبق درخواست کاربر): «Hermes Dashboard : <آدرس>» و
#     «9Router Terminal : <آدرس>».
#     (REPORT_BOT_TOKEN + NOTIFY_CHAT_ID در /root/.hermes/.env که هر بوت از
#     GitHub Secrets تزریق می‌شود و هرگز در آرشیو state نمی‌ماند) ارسال می‌شود.
#   * آخرین آدرسهای اعلام‌شده در /root/.tunnel-watch/last.json (ماندگار بین
#     رانرها) → بعد از هر ریبیلد، آدرس تازه با قبلی فرق دارد → خودکار اعلام.
#   * سلامت تونل با چک HTTP عمومی تأیید می‌شود (401 = پشت nginx auth = سالم).
# ============================================================================
set -u
STATE_DIR=/root/.tunnel-watch
LAST="$STATE_DIR/last.json"
ENVF=/root/.hermes/.env
INTERVAL="${TUNNEL_WATCH_INTERVAL:-30}"
mkdir -p "$STATE_DIR"
[ -s "$LAST" ] || echo '{}' > "$LAST"

log() { echo "[tunnel-watch $(date -u '+%T')] $*"; }

tg_report() {  # $1 = text — فقط ربات گزارش، هیچ کانال دیگری
  local TOK CHAT
  TOK=$(grep -m1 '^REPORT_BOT_TOKEN=.\{8,\}' "$ENVF" 2>/dev/null | cut -d= -f2-)
  CHAT=$(grep -m1 '^NOTIFY_CHAT_ID=.' "$ENVF" 2>/dev/null | cut -d= -f2-)
  if [ -z "${TOK:-}" ] || [ -z "${CHAT:-}" ]; then
    log "WARN: REPORT_BOT_TOKEN/NOTIFY_CHAT_ID in $ENVF missing — announce skipped"
    return 1
  fi
  if curl -fsS -m 20 -X POST "https://api.telegram.org/bot${TOK}/sendMessage" \
       -d "chat_id=${CHAT}" -d "disable_web_page_preview=true" \
       --data-urlencode "text=$1" >/dev/null 2>&1; then
    log "announced via REPORT bot"
  else
    log "WARN: telegram send failed"
  fi
}

# name|unit|urlfile|label
TUNNELS="hermes|hermes-tunnel.service|/root/.hermes/tunnel_url.txt|Hermes Dashboard
9router|9router-tunnel.service|/root/.9router/tunnel_url.txt|9Router Terminal"

log "started (interval=${INTERVAL}s, report-bot only)"
while :; do
  while IFS='|' read -r NAME UNIT URLFILE LABEL; do
    [ -n "$NAME" ] || continue
    URL=$(head -1 "$URLFILE" 2>/dev/null || true)
    PREV=$(jq -r --arg n "$NAME" '.[$n] // ""' "$LAST" 2>/dev/null || echo "")
    ACTIVE=$(systemctl is-active "$UNIT" 2>/dev/null || echo unknown)
    if [ "$ACTIVE" = "activating" ]; then
      : # در حال بالا آمدن — کاری نکن (جلوگیری از لوپ ری‌استارت موقع بوت)
    elif [ "$ACTIVE" != "active" ]; then
      log "$NAME: unit=$ACTIVE — restarting $UNIT"
      rm -f "$URLFILE"
      systemctl restart "$UNIT" >/dev/null 2>&1 || true
    elif [ -n "${URL:-}" ] && [ "$URL" != "$PREV" ]; then
      # چک سلامت عمومی با ۳ تلاش (edge propagation چند ثانیه طول می‌کشد)
      HTTP=000
      for try in 1 2 3; do
        HTTP=$(curl -s -o /dev/null -w "%{http_code}" -m 12 "$URL/" 2>/dev/null || echo 000)
        case "$HTTP" in 200|301|302|307|308|401|403) break;; esac
        sleep 5
      done
      case "$HTTP" in
        200|301|302|307|308|401|403)
          log "$NAME: NEW URL $URL (public HTTP $HTTP) — announcing"
          # فقط در صورت موفقیت ارسال، آدرس «اعلام‌شده» ثبت می‌شود (اعلان ازدست‌رفته
          # در چرخه‌ی بعد دوباره تلاش می‌شود)
          if tg_report "${LABEL} : ${URL}"; then
            TMP=$(mktemp)
            jq --arg n "$NAME" --arg u "$URL" --arg t "$(date -u '+%FT%TZ')" \
               '.[$n]=$u | .[$n+"_ts"]=$t' "$LAST" > "$TMP" 2>/dev/null && mv "$TMP" "$LAST"
          fi
          ;;
        *)
          log "$NAME: URL $URL failed public check 3x (HTTP $HTTP) — restarting tunnel"
          rm -f "$URLFILE"
          systemctl restart "$UNIT" >/dev/null 2>&1 || true
          ;;
      esac
    fi
  done <<< "$TUNNELS"
  sleep "$INTERVAL"
done
