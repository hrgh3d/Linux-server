#!/usr/bin/env bash
# gateway_guard.sh — v6.30
# نگهبان دائمی «اتصال واقعی» ربات تلگرام Hermes.
#
# چرا لازم است؟ (رخداد ۱۶ سپتامبر ۲۰۲۶ — زنجیرهٔ کامل علت)
#   save.sh عمداً TELEGRAM_BOT_TOKEN را قبل از tar خالی می‌کند تا توکن وارد
#   آرشیو state نشود، و بلافاصله بعد از tar برش می‌گرداند. اگر آن ران در همان
#   پنجره کشته شود (کرش/لغو/پایان عمر رانر)، توکن برای همیشه خالی می‌ماند.
#   گیت‌وی بعدی با .env بی‌توکن بالا می‌آید و لاگ می‌کند:
#       WARNING gateway.run: No messaging platforms enabled.
#   پروسه کاملاً سالم است (is-active=active، pgrep=OK، NRestarts=0، بدون کرش)
#   ولی هیچ پلتفرمی لود نشده → ربات کر است. هیچ health-check موجودی این حالت
#   را نمی‌گرفت؛ همه‌چیز «سبزِ گمراه‌کننده» بود.
#
# این نگهبان فقط «اتصال مؤثر» را می‌سنجد، نه زنده‌بودن پروسه:
#   * توکن در .env خالی است؟ → از بکاپ‌ها بازیابی کن و ری‌استارت بده.
#   * گیت‌وی بالاست ولی از زمان آخرین استارتش خط
#     "Connected to Telegram (polling mode)" ندیده‌ایم؟ → ری‌استارت.
#   * هرگز به فایل‌های سشن (~/.hermes/sessions) دست نمی‌زند.
#   * flock: هرگز دو نمونه هم‌زمان اجرا نمی‌شود.
#   * پنجرهٔ blanking خودِ save.sh را می‌شناسد و در آن دخالت نمی‌کند
#     (sentinel: /run/hermes-env-blanked)، مگر اینکه کهنه شده باشد → یعنی
#     save.sh واقعاً مرده و باید ترمیم کرد.
#   * کول‌داون دارد تا حلقهٔ ری‌استارت نسازد.
set -uo pipefail

# --- قفل: فقط یک نمونه در هر لحظه ---
LOCK=/run/hermes-gateway-guard.lock
if [ -z "${_GUARD_LOCKED:-}" ]; then
  export _GUARD_LOCKED=1
  exec flock -n "$LOCK" "$0" "$@" || exit 0
fi

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
  # اولویت با نسخه‌ای است که save.sh دقیقاً قبل از blank کردن نگه داشته
  for src in /var/lib/hermes-guard/env.preblank /root/hermes-pre-update-keep/.env /root/hermes-env-broken-*.bak; do
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

# v6.30 — پروسه‌های یتیم گیت‌وی.
# ۱۶ سپتامبر: بعد از یک بوت، دو پروسهٔ gateway هم‌زمان زنده بودند (۹۸۸۸ یتیم از
# بوت قبلی + پروسهٔ واقعی یونیت). یتیم قفل long-polling تلگرام را نگه داشته بود،
# پس پروسهٔ جدید هرگز وصل نمی‌شد و `systemctl restart` هم آن را نمی‌کشت (خارج از
# cgroup یونیت بود). ربات ساعت‌ها کر ماند در حالی که همه‌چیز active بود.
# قبل از هر ری‌استارت، هر پروسهٔ gateway که MainPID یونیت نیست کشته می‌شود.
kill_orphan_gateways() {
  local main p killed=0
  main=$(uc show "$UNIT" -p MainPID --value)
  for p in $(pgrep -f 'hermes_cli.main gateway' 2>/dev/null); do
    [ "$p" = "$main" ] && continue
    kill -TERM "$p" 2>/dev/null && killed=$((killed+1))
  done
  [ "$killed" -eq 0 ] && return 0
  sleep 5
  for p in $(pgrep -f 'hermes_cli.main gateway' 2>/dev/null); do
    [ "$p" = "$main" ] && continue
    kill -9 "$p" 2>/dev/null
  done
  log "killed $killed orphan gateway process(es) holding the Telegram poll lock"
}

do_restart() {
  local why="$1"
  if ! cooldown_ok; then log "restart needed ($why) but cooldown active — skip"; return 0; fi
  date +%s > "$STAMP"
  log "RESTARTING gateway — reason: $why"
  kill_orphan_gateways
  uc restart "$UNIT" || {
    log "user unit restart failed; direct fallback"
    pkill -f 'hermes_cli.main gateway' 2>/dev/null
    sleep 2
    nohup /usr/local/lib/hermes-agent/venv/bin/python -m hermes_cli.main gateway run \
      >>/var/log/hermes-gateway.log 2>&1 &
  }
}

# save.sh در حال آرشیوگیری، توکن را موقتاً خالی کرده است؟
# اگر sentinel تازه باشد دخالت نکن؛ اگر کهنه باشد یعنی آن ران مرده → ترمیم کن.
#
# v6.29 — رفع باگ «standing by ابدی»: save.sh هر ۵ دقیقه اجرا می‌شود و sentinel
# را دوباره تازه می‌کند. با تکیه بر سن sentinel به‌تنهایی، نگهبان می‌توانست
# بی‌نهایت منتظر بماند و توکنِ خالی ساعت‌ها دست‌نخورده بماند (۱۶ سپتامبر: شش
# بار پشت‌سرهم «standing by» در ۲۵ دقیقه، در حالی که هیچ save.sh زنده نبود).
# حالا دو شرط دیگر هم لازم است:
#   ۱) واقعاً پروسهٔ save.sh/tar در حال اجرا باشد، و
#   ۲) از اولین باری که توکن را خالی دیدیم بیش از سقف مطلق نگذشته باشد.
in_backup_window() {
  local s=/run/hermes-env-blanked
  local seen=/var/lib/hermes-guard/blank-first-seen
  local now; now=$(date +%s)

  if [ ! -f "$s" ]; then rm -f "$seen" 2>/dev/null; return 1; fi

  local age=$(( now - $(stat -c %Y "$s" 2>/dev/null || echo 0) ))
  if [ "$age" -ge "${GUARD_BLANK_GRACE_SEC:-420}" ]; then
    rm -f "$seen" 2>/dev/null; return 1
  fi

  # sentinel تازه است، ولی آیا آرشیوگیری واقعاً در جریان است؟
  if ! pgrep -f 'save\.sh|tar -c .*state\.tar' >/dev/null 2>&1; then
    log "sentinel fresh but no save.sh/tar running — treating as stale"
    rm -f "$s" "$seen" 2>/dev/null
    return 1
  fi

  # سقف مطلق: از اولین مشاهدهٔ توکن خالی بیشتر از این صبر نمی‌کنیم
  [ -f "$seen" ] || printf '%s' "$now" > "$seen"
  local waited=$(( now - $(cat "$seen" 2>/dev/null || echo "$now") ))
  if [ "$waited" -ge "${GUARD_BLANK_MAX_WAIT_SEC:-900}" ]; then
    log "blank token persisted ${waited}s across archive windows — repairing anyway"
    rm -f "$seen" 2>/dev/null
    return 1
  fi
  return 0
}

# v6.27: REPORT_BOT_TOKEN هم در همان پنجرهٔ blank شدن save.sh قربانی می‌شود.
# بدون آن، اعلان‌های تونل و تحویل اعتبارنامه‌ها بی‌صدا شکست می‌خورند (۱۶ سپتامبر
# هنگام نصب OpenClaw کشف شد: len=0). این تابع آن را مستقل از توکن Hermes ترمیم
# می‌کند — بدون ری‌استارت گیت‌وی، چون فقط اسکریپت‌های سمت سرور از آن می‌خوانند.
restore_report_token() {
  local cur src t
  cur=$(sed -n 's/^REPORT_BOT_TOKEN=//p' "$ENV_FILE" 2>/dev/null | head -1 | tr -d '\r "'"'"'')
  [ ${#cur} -ge 20 ] && return 0
  in_backup_window && return 0
  for src in /var/lib/hermes-guard/env.preblank /root/hermes-pre-update-keep/.env /root/hermes-env-broken-*.bak; do
    [ -f "$src" ] || continue
    t=$(sed -n 's/^REPORT_BOT_TOKEN=//p' "$src" 2>/dev/null | head -1 | tr -d '\r "'"'"'')
    [ ${#t} -ge 20 ] && break
    t=""
  done
  [ -z "$t" ] && [ -n "${REPORT_BOT_TOKEN:-}" ] && t="$REPORT_BOT_TOKEN"
  [ -z "$t" ] && { log "REPORT_BOT_TOKEN empty and no backup source found"; return 1; }
  python3 - "$ENV_FILE" "$t" <<'PY'
import sys,re
p,tok=sys.argv[1],sys.argv[2]
out=[];done=False
for ln in open(p,errors='replace').read().splitlines():
    if not done and re.match(r'^REPORT_BOT_TOKEN=',ln):
        out.append("REPORT_BOT_TOKEN="+tok); done=True
    else: out.append(ln)
if not done: out.append("REPORT_BOT_TOKEN="+tok)
open(p,'w').write("\n".join(out)+"\n")
PY
  chmod 600 "$ENV_FILE" 2>/dev/null || true
  log "REPORT_BOT_TOKEN restored (len=${#t})"
}

main() {
  [ -f "$ENV_FILE" ] || { log "no $ENV_FILE — nothing to guard"; exit 0; }

  restore_report_token

  local tok; tok=$(read_token)
  if [ ${#tok} -lt 20 ]; then
    if in_backup_window; then
      log "token blank but save.sh archive window is active — standing by"
      exit 0
    fi
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

  # v6.30: بیش از یک پروسهٔ gateway = یتیم وجود دارد و قفل polling را گرفته.
  # این حالت خودش به‌تنهایی دلیل کافی برای ترمیم است، حتی اگر لاگ چیزی نگوید.
  if [ "$(pgrep -cf 'hermes_cli.main gateway')" -gt 1 ]; then
    do_restart "multiple gateway processes (orphan holding the poll lock)"
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
