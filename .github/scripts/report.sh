#!/bin/bash
# ============================================================================
# report.sh (v6.47) — تنها دروازهٔ ارسال به تلگرام برای کل سیستم
#
# پیش از این نسخه، شش اسکریپت مختلف مستقیماً به api.telegram.org کرل می‌زدند و
# هرکدام توکن را از جای خودش برمی‌داشت (REPORT_BOT_TOKEN، TELEGRAM_BOT_TOKEN،
# فایل‌های /run/...). نتیجه: گزارش‌ها بین چند ربات پخش می‌شد.
#
# از v6.47 طبق درخواست کاربر «فقط ربات آخر، نه هیچ جای دیگر»:
#   - تنها منبع مقصد = REPORT_BOT_TOKEN (ربات @hrgh3dreportbot) + NOTIFY_CHAT_ID
#   - TELEGRAM_BOT_TOKEN فقط برای گفتگوی Hermes است و هرگز برای گزارش نیست
#   - هیچ اسکریپتی حق ندارد مستقیم curl به تلگرام بزند — همه از اینجا رد شوند
#
# Usage:
#   report.sh text  "<متن>"                 → sendMessage
#   report.sh file  "<مسیر>" ["<کپشن>"]     → sendDocument
#   report.sh check                          → صحت‌سنجی مقصد (getMe) بدون ارسال
#
# خروجی: 0 = تحویل شد، غیرصفر = نشد (متن خطا روی stderr)
# ============================================================================
set -u

ENVF="${HERMES_ENV_FILE:-/root/.hermes/.env}"
STATE_DIR=/root/.report
CRED_CACHE="$STATE_DIR/.creds"
mkdir -p "$STATE_DIR" 2>/dev/null || true

log() { echo "[report $(date -u '+%T')] $*" >&2; }

# --- resolve the ONE destination -------------------------------------------
# ترتیب: متغیر محیطی → فایل .env → کش → فایل‌های توکن روی دیسک.
# عمداً TELEGRAM_BOT_TOKEN در این زنجیره نیست: آن ربات Hermes است و گزارش
# سیستم نباید کانال گفتگو را اشغال کند.
resolve_creds() {
  local tok="" chat=""

  tok="${REPORT_BOT_TOKEN:-}"
  [ -n "$tok" ] || tok=$(grep -m1 '^REPORT_BOT_TOKEN=.\{8,\}' "$ENVF" 2>/dev/null | cut -d= -f2-)
  if [ -z "$tok" ]; then
    for f in /run/report-bot.token /root/.hermes/.report-bot.token; do
      [ -s "$f" ] && tok="$(tr -d '\r\n' < "$f")" && break
    done
  fi
  # پنجرهٔ خالی‌سازی save.sh: از نسخهٔ پیش از blank شدن بخوان
  if [ -z "$tok" ]; then
    local pre
    pre="$(ls -1t /root/.hermes/.env.pre-guard.* /var/lib/hermes-guard/env.preblank 2>/dev/null | head -1)"
    [ -n "$pre" ] && tok=$(grep -m1 '^REPORT_BOT_TOKEN=.\{8,\}' "$pre" 2>/dev/null | cut -d= -f2-)
  fi

  chat="${NOTIFY_CHAT_ID:-}"
  [ -n "$chat" ] || chat=$(grep -m1 '^NOTIFY_CHAT_ID=.' "$ENVF" 2>/dev/null | cut -d= -f2-)

  if [ -n "$tok" ] && [ -n "$chat" ]; then
    (umask 077; printf '%s\t%s' "$tok" "$chat" > "$CRED_CACHE") 2>/dev/null || true
    printf '%s\t%s' "$tok" "$chat"; return 0
  fi
  if [ -s "$CRED_CACHE" ]; then cat "$CRED_CACHE"; return 0; fi
  return 1
}

CREDS=$(resolve_creds) || { log "FATAL: no report-bot destination available"; exit 3; }
TOK="${CREDS%%$'\t'*}"; CHAT="${CREDS##*$'\t'}"
API="https://api.telegram.org/bot${TOK}"

MODE="${1:-text}"; shift || true

case "$MODE" in
  check)
    if curl -fsS -m 15 "${API}/getMe" 2>/dev/null | grep -q '"ok":true'; then
      log "destination OK (chat ${CHAT})"; exit 0
    fi
    log "destination UNREACHABLE"; exit 1 ;;

  text)
    TEXT="${1:-}"
    [ -n "$TEXT" ] || { log "empty text"; exit 2; }
    # تلگرام سقف ۴۰۹۶ کاراکتر دارد؛ برش امن روی مرز خط
    LIMIT=3900
    RC=1
    while [ -n "$TEXT" ]; do
      CHUNK="${TEXT:0:$LIMIT}"
      if [ "${#TEXT}" -gt "$LIMIT" ]; then
        CUT="${CHUNK%$'\n'*}"
        [ -n "$CUT" ] && [ "${#CUT}" -gt 200 ] && CHUNK="$CUT"
      fi
      for attempt in 1 2 3; do
        if curl -fsS -m 25 -X POST "${API}/sendMessage" \
             -d "chat_id=${CHAT}" -d "disable_web_page_preview=true" \
             --data-urlencode "text=${CHUNK}" >/dev/null 2>&1; then
          RC=0; break
        fi
        RC=1; sleep $((attempt * 2))
      done
      [ "$RC" -eq 0 ] || { log "send failed after 3 attempts"; exit 1; }
      TEXT="${TEXT:${#CHUNK}}"
      TEXT="${TEXT#$'\n'}"
    done
    exit 0 ;;

  file)
    FP="${1:-}"; CAP="${2:-}"
    [ -s "$FP" ] || { log "file missing/empty: $FP"; exit 2; }
    for attempt in 1 2 3; do
      if curl -fsS -m 300 -X POST "${API}/sendDocument" \
           -F "chat_id=${CHAT}" -F "document=@${FP}" \
           -F "caption=${CAP:0:1000}" >/dev/null 2>&1; then
        exit 0
      fi
      sleep $((attempt * 3))
    done
    log "document send failed: $FP"; exit 1 ;;

  *) log "unknown mode: $MODE"; exit 2 ;;
esac
