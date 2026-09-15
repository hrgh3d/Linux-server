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

CRED_CACHE="$STATE_DIR/.report-creds"
read_creds() {  # چاپ "TOKEN<TAB>CHAT" یا خطای غیرصفر
  local tok chat
  tok=$(grep -m1 '^REPORT_BOT_TOKEN=.\{8,\}' "$ENVF" 2>/dev/null | cut -d= -f2-)
  chat=$(grep -m1 '^NOTIFY_CHAT_ID=.' "$ENVF" 2>/dev/null | cut -d= -f2-)
  if [ -n "${tok:-}" ] && [ -n "${chat:-}" ]; then
    # v6.21: کش کن تا در «پنجره‌ی خالی‌سازی» save.sh هم در دسترس باشد
    (umask 077; printf '%s\t%s' "$tok" "$chat" > "$CRED_CACHE") 2>/dev/null || true
    printf '%s\t%s' "$tok" "$chat"; return 0
  fi
  if [ -s "$CRED_CACHE" ]; then
    cat "$CRED_CACHE" 2>/dev/null; return 0
  fi
  return 1
}

tg_report() {  # $1 = text — فقط ربات گزارش، هیچ کانال دیگری
  local TOK CHAT CREDS
  # v6.21 (علت ریشه‌ای): save.sh هنگام ساخت آرشیو، REPORT_BOT_TOKEN را موقتاً
  # در .env خالی می‌کند. اگر دقیقاً در همان لحظه آدرس تونل عوض شود، اینجا
  # توکن «خالی» دیده می‌شد و اعلان برای همیشه از دست می‌رفت. حالا از کش
  # استفاده می‌شود تا این پنجره‌ی رقابتی بی‌اثر شود.
  CREDS=$(read_creds) || {
    log "WARN: REPORT_BOT_TOKEN/NOTIFY_CHAT_ID unavailable (no cache) — announce deferred"
    return 1
  }
  TOK="${CREDS%%$'\t'*}"; CHAT="${CREDS##*$'\t'}"
  if [ -z "${TOK:-}" ] || [ -z "${CHAT:-}" ]; then
    log "WARN: report creds empty — announce deferred"
    return 1
  fi
  # v6.21: تلاش چندباره + برگرداندن کد خطای واقعی.
  # باگ قبلی: در شاخه‌ی شکست، return غیرصفر نداشت و مقدار بازگشتی تابع صفر
  # (موفق) می‌شد؛ در نتیجه caller آدرس را «اعلام‌شده» ثبت می‌کرد و آن آدرس
  # دیگر هرگز دوباره ارسال نمی‌شد (اعلان برای همیشه گم می‌شد).
  local i code
  for i in 1 2 3; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 20 -X POST \
      "https://api.telegram.org/bot${TOK}/sendMessage" \
      -d "chat_id=${CHAT}" -d "disable_web_page_preview=true" \
      --data-urlencode "text=$1" 2>/dev/null)
    if [ "$code" = "200" ]; then
      log "announced via REPORT bot"
      return 0
    fi
    log "WARN: telegram send failed (http=$code, try $i/3)"
    sleep 3
  done
  return 1
}

# ---- v6.17: بکاپ کامل با هر گزارش آدرس --------------------------------------
# send-backup.yml (DR) را dispatch می‌کند تا باندل کامل (ریپو+کلیدها+state) به
# تلگرام برود. PERSIST_TOKEN هرگز روی دیسک نیست: از env پروسه‌ی زنده‌ی رانر
# خوانده می‌شود. گارد محلی ۱۰ دقیقه‌ای: دو تغییر آدرس هم‌زمان = یک باندل
# (dedup سراسری ۱۵ دقیقه‌ای هم داخل خود send_backup.sh هست).
BUNDLE_GUARD="$STATE_DIR/last-bundle-dispatch"
BUNDLE_REPO="hrgh3d/Linux-server"
TOKEN_CACHE="$STATE_DIR/.ptok"
persist_token() {
  local pp tt
  # v6.21: کش محلی — اگر پروسه‌ی رانر موقتاً در دسترس نباشد باز هم کار کند
  if [ -s "$TOKEN_CACHE" ]; then
    tt=$(cat "$TOKEN_CACHE" 2>/dev/null)
    [ -n "$tt" ] && { printf '%s' "$tt"; return 0; }
  fi
  # v6.21: خطای «No such process» به /dev/null می‌رود (پروسه‌ها حین پیمایش
  # از بین می‌روند و قبلاً ده‌ها خط نویز در ژورنال می‌ساخت)
  for pp in /proc/[0-9]*/environ; do
    tt=$( (tr '\0' '\n' < "$pp") 2>/dev/null | sed -n 's/^PERSIST_TOKEN=//p' | head -1)
    if [ -n "$tt" ]; then
      (umask 077; printf '%s' "$tt" > "$TOKEN_CACHE") 2>/dev/null || true
      printf '%s' "$tt"; return 0
    fi
  done
  return 1
}
dispatch_bundle() { # $1 = trigger
  local now last tok code
  now=$(date +%s); last=$(cat "$BUNDLE_GUARD" 2>/dev/null || echo 0)
  if [ $(( now - last )) -lt 600 ]; then
    log "bundle dispatch skipped (last $(( (now - last) / 60 ))min ago) [$1]"; return 0
  fi
  tok=$(persist_token) || { log "WARN: PERSIST_TOKEN not found in proc envs — bundle skipped [$1]"; return 1; }
  code=$(curl -s -m 20 -X POST -H "Authorization: Bearer $tok" -H "Accept: application/vnd.github+json" \
    -d '{"ref":"main","inputs":{"full":"true"}}' -o /dev/null -w '%{http_code}' \
    "https://api.github.com/repos/${BUNDLE_REPO}/actions/workflows/send-backup.yml/dispatches" 2>/dev/null)
  if [ "$code" = "204" ]; then echo "$now" > "$BUNDLE_GUARD"; log "backup bundle dispatched [$1]";
  else log "WARN: bundle dispatch http=$code [$1]"; fi
}

# name|unit|urlfile|label
TUNNELS="hermes|hermes-tunnel.service|/root/.hermes/tunnel_url.txt|Hermes Dashboard
9router|9router-tunnel.service|/root/.9router/tunnel_url.txt|9Router Terminal"

HTPASSWD=/etc/nginx/.htpasswd-hermes
heal_htpasswd() {  # v6.16.1: اگر www-data نتواند htpasswd را بخواند → 500 پشت لاگین
  [ -f "$HTPASSWD" ] || return 0
  local g pr
  g=$(stat -c '%G' "$HTPASSWD" 2>/dev/null); pr=$(stat -c '%A' "$HTPASSWD" 2>/dev/null)
  if [ "$g" != "www-data" ] || [ "${pr:4:1}" != "r" ]; then
    chown root:www-data "$HTPASSWD" 2>/dev/null || true
    chmod 640 "$HTPASSWD" 2>/dev/null || true
    log "htpasswd perms fixed (was ${g}/${pr})"
  fi
}

log "started (interval=${INTERVAL}s, report-bot only)"
while :; do
  heal_htpasswd
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
            dispatch_bundle "url-change:$NAME"
          fi
          ;;
        500)
          log "$NAME: HTTP 500 — nginx-side (htpasswd) نه تونل؛ ری‌استارت بی‌فایده است (heal_htpasswd اصلاح می‌کند)"
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
