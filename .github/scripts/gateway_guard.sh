#!/usr/bin/env bash
# gateway_guard.sh — v6.24
# نگهبان دائمی «اتصال واقعی» ربات تلگرام Hermes.
#
# چرا لازم است؟
#   ۱۶ سپتامبر ۲۰۲۶: بعد از نصب مجدد Hermes، گیت‌وی در حالی بالا آمد که
#   TELEGRAM_BOT_TOKEN هنوز در .env تزریق نشده بود. نتیجه:
#       WARNING gateway.run: No messaging platforms enabled.
#   پروسه «سالم» بود (systemctl is-active = active، pgrep = OK، بدون کرش)
#   ولی هیچ پلتفرم پیام‌رسانی لود نشده بود → ربات کاملاً کر بود.
#   توکن چند دقیقه بعد توسط self-heal برگشت، اما گیت‌وی ری‌استارت نشد،
#   پس تا ساعت‌ها بی‌صدا ماند. هیچ health-check موجودی این را نمی‌گرفت.
#
# این نگهبان فقط و فقط «اتصال مؤثر» را می‌سنجد، نه زنده‌بودن پروسه:
#   * توکن در .env خالی است؟ → از بکاپ‌ها بازیابی کن.
#   * گیت‌وی بالاست ولی از زمان آخرین استارتش خط
#     "Connected to Telegram (polling mode)" ندیده‌ایم؟ → ری‌استارت.
#   * هرگز به فایل‌های سشن (~/.hermes/sessions) دست نمی‌زند.
#   * کول‌داون دارد تا حلقهٔ ری‌استارت نسازد.
set -uo pipefail

HERMES_HOME="${HERMES_HOME:-/root/.hermes}"
ENV_FILE="$HERMES_HOME/.env"
UNIT="hermes-gateway.service"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/0}"
STATE_DIR=/var/lib/hermes-guard
STAMP="$STATE_DIR/last-restart"
COOLDOWN_SEC="${GUARD_COOLDOWN_SEC:-300}"   # حداکثر یک ری‌استارت هر ۵ دقیقه
GRACE_SEC="${GUARD_GRACE_SEC:-90}"          # به استارت تازه فرصت اتصال بده
LOG=/var/log/hermes-gateway-guard.log

mkdir -p "$STATE_DIR" 2>/dev/null || true
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG" >/dev/null; }

uc() { systemctl --user "$@" 2>/dev/null; }

# ---------- ۱) توکن باید موجود و غیرخالی باشد ----------
read_token() {
  [ -f "$ENV_FILE" ] || { echo ""; return; }
  grep -m1 '^TELEGRAM_BOT_TOKEN=' "$ENV_FILE" 2>/dev/null \
    | cut -d= -f2- | tr -d '"'"'"' \r' | head -c 200
}

restore_token() {
  # منابع بازیابی به ترتیب اولویت: بکاپ قبل از آپدیت، بکاپ‌های خودکار، متغیر محیطی CI
  local t=""
  for src in /root/hermes-pre-update-keep/.env /root/hermes-env-broken-*.bak; do
    [ -f "$src" ] || continue
    t=$(grep -m1 '^TELEGRAM_BOT_TOKEN=' "$src" 2>/dev/null | cut -d= -f2- | tr -d '"'"'"' \r')
    [ -n "$t" ] && { log "token restored from $src"; break; }
  done
  [ -z "$t" ] && [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && { t="$TELEGRAM_BOT_TOKEN"; log "token taken from environment"; }
  [ -z "$t" ] && return 1

  cp -a "$ENV_FILE" "$ENV_FILE.pre-guard.$(date -u +%Y%m%d-%H%M%S)" 2>/dev/null || true
  if grep -q '^TELEGRAM_BOT_TOKEN=' "$ENV_FILE" 2>/dev/null; then
    # فقط خط فعال (غیرکامنت) را جایگزین کن
    python3 - "$ENV_FILE" "$t" <<'PY'
import sys,re
p,tok=sys.argv[1],sys.argv[2]
out=[];done=False
for ln in open(p,errors='replace').read().splitlines():
    if not done and re.match(r'^TELEGRAM_BOT_TOKEN=',ln):
        out.append("TELEGRAM_BOT_TOKEN="+tok); done=True
    else: out.append(ln)
if not done: out.append("TELEGRAM_BOT_TOKEN="+tok)
open(p,'w').write("\n".join(out)+"\n")
PY
  else
    printf 'TELEGRAM_BOT_TOKEN=%s\n' "$t" >> "$ENV_FILE"
  fi
  chmod 600 "$ENV_FILE" 2>/dev/null || true
  return 0
}

# ---------- ۲) آیا واقعاً به تلگرام وصل است؟ ----------
# از زمان آخرین استارت یونیت، دنبال خط اتصال بگرد.
gateway_started_epoch() {
  local ts
  ts=$(uc show "$UNIT" -p ExecMainStartTimestamp --value)
  [ -z "$ts" ] && { echo 0; return; }
  date -d "$ts" +%s 2>/dev/null || echo 0
}

telegram_attached() {
  local since="$1" out
  out=$(journalctl --user -u "$UNIT" --since "@$since" --no-pager 2>/dev/null)
  [ -z "$out" ] && out=$(tail -n 500 /var/log/hermes-gateway.log 2>/dev/null)
  if printf '%s' "$out" | grep -q 'Connected to Telegram (polling mode)'; then return 0; fi
  if printf '%s' "$out" | grep -q 'No messaging platforms enabled'; then return 1; fi
  return 2   # نامعلوم → دست نگه دار
}

cooldown_ok() {
  [ -f "$STAMP" ] || return 0
  local last now; last=$(cat "$STAMP" 2>/dev/null || echo 0); now=$(date +%s)
  [ $((now - last)) -ge "$COOLDOWN_SEC" ]
}

do_restart() {
  local why="$1"
  if ! cooldown_ok; then log "restart needed ($why) but cooldown active — skip"; return 0; fi
  date +%s > "$STAMP"
  log "RESTARTING gateway — reason: $why"
  uc restart "$UNIT" || {
    log "user unit restart failed; direct fallback"
    pkill -f 'hermes_cli.main gateway' 2>/dev/null
    sleep 2
    nohup /usr/local/lib/hermes-agent/venv/bin/python -m hermes_cli.main gateway run \
      >>/var/log/hermes-gateway.log 2>&1 &
  }
}

main() {
  [ -f "$ENV_FILE" ] || { log "no $ENV_FILE — nothing to guard"; exit 0; }

  local tok; tok=$(read_token)
  if [ ${#tok} -lt 20 ]; then
    log "TELEGRAM_BOT_TOKEN missing/empty (len=${#tok}) — attempting restore"
    if restore_token; then
      do_restart "token restored into .env"
      exit 0
    fi
    log "ERROR: could not restore a Telegram token from any backup"
    exit 0
  fi

  # پروسه اصلاً بالا هست؟
  if ! pgrep -f 'hermes_cli.main gateway' >/dev/null 2>&1; then
    do_restart "gateway process not running"
    exit 0
  fi

  local start now age; start=$(gateway_started_epoch); now=$(date +%s); age=$((now - start))
  [ "$start" -eq 0 ] && age=99999
  if [ "$age" -lt "$GRACE_SEC" ]; then exit 0; fi   # تازه بالا آمده، فرصت بده

  telegram_attached "$start"; local rc=$?
  case "$rc" in
    0) : ;;                                              # سالم
    1) do_restart "gateway up but no messaging platform attached" ;;
    *) : ;;                                              # نامعلوم → کاری نکن
  esac
}

main "$@"
