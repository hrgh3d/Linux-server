#!/bin/bash
# send_backup.sh (hrgh3d) — بکاپ کامل + قابل‌بازگردانی روی حساب گیت‌هاب جدید
#   • بکاپ داده‌های سرور (کانفیگ‌ها، دیتابیس‌ها، پوشه‌های مهم)
#   • + بوت‌استرپ بازیابی: محتوای کل ریپو، کلید/توکن‌ها (Base64)، RECOVERY.md
#   • در حالت DR (هفتگی/دستی): اسنپ‌شات state هم بخش‌بخش ارسال می‌شود
# env: REPO, STATE_REPO, VPS_NAME, TARGET_IP, HAMID_PASSWORD, TAILSCALE_AUTH_KEY,
#      TELEGRAM_BOT_TOKEN, NOTIFY_CHAT_ID, STATE_TOKEN, PERSIST_TOKEN, DR_MODE,
#      + همهٔ سکرت‌های ریپو برای فایل بازیابی
set -uo pipefail

VPS_NAME="${VPS_NAME:-$(basename "${REPO:-vps}")}"
TS_HOSTNAME="${TS_HOSTNAME:-hrg-backup}"
LIMIT=$((45 * 1024 * 1024))
PART=$((40 * 1024 * 1024))
DR_MODE="${DR_MODE:-false}"

echo "[backup] $(date -u +%FT%TZ) vps=${VPS_NAME} target=${TARGET_IP} dr=${DR_MODE}"

# ---------- ۰) بوت‌استرپ بازیابی (روی runner) ----------
BK=/tmp/bootstrap; rm -rf "$BK"; mkdir -p "$BK/recovery"
if git rev-parse --git-dir >/dev/null 2>&1; then
  git archive --format=tar.gz -o "$BK/repo.tar.gz" HEAD 2>/dev/null && echo "[backup] repo bundle OK ($(stat -c%s "$BK/repo.tar.gz") bytes)"
fi
if [ -f .github/recovery/RECOVERY.md ]; then cp .github/recovery/RECOVERY.md "$BK/recovery/RECOVERY.md"; fi
{
  echo "# کلیدهای بازیابی — مقادیر Base64 هستند. برای دیدن مقدار: base64 -d <<< '<مقدار>'"
  echo "# این‌ها را به‌عنوان سکرت ریپوی جدید ثبت کن (نام‌ها همان‌ها). تاریخ: $(date -u +%FT%TZ)"
  for n in HAMID_PASSWORD PERSIST_TOKEN STATE_TOKEN SUCCESSOR_TOKEN TAILSCALE_AUTH_KEY \
           TAILSCALE_API_TOKEN TAILSCALE_FIXED_IP TELEGRAM_BOT_TOKEN NOTIFY_CHAT_ID \
           MIRZABOT_TOKEN MIRZABOT_ADMIN_ID MIRZABOT_ADMIN_USER MIRZABOT_BOT_NAME MIRZABOT_BRAND \
           XUI_RESET_USER XUI_RESET_PASS DASHBOARD_PASSWORD; do
    v="$(eval "printf '%s' \"\${$n:-}\"")"
    [ -n "$v" ] && printf '%s=%s\n' "$n" "$(printf '%s' "$v" | base64 -w0)"
  done
} > "$BK/recovery/secrets.env"
echo "[backup] recovery keys: $(grep -c '=' "$BK/recovery/secrets.env") مورد"
{
  echo "vps=$VPS_NAME"; echo "time=$(date -u +%FT%TZ)"; echo "repo=$REPO"; echo "state_repo=$STATE_REPO"
  echo "files:"; ls -l "$BK" "$BK/recovery" 2>/dev/null | awk '{print "  "$9" "$5}'
} > "$BK/manifest.txt"

# ---------- ۱) بکاپ سرور (روی سرور hrgh3d) ----------
sudo apt-get update -qq >/dev/null 2>&1 || true
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o DPkg::Lock::Timeout=120 \
  curl jq sshpass openssh-client ca-certificates >/dev/null 2>&1 || true

if [ -n "${TAILSCALE_AUTH_KEY:-}" ] && ! tailscale status >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1 || true
  sudo tailscale up --authkey="${TAILSCALE_AUTH_KEY}" --hostname="${TS_HOSTNAME}" --accept-routes --ssh=false \
    >/tmp/tsup.log 2>&1 || { echo "[backup] tailscale up failed"; tail -5 /tmp/tsup.log; }
  for _ in $(seq 1 20); do sudo tailscale status --json 2>/dev/null | jq -e '.Self.Online==true' >/dev/null 2>&1 && break || sleep 2; done
fi

SSHOPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/known_hosts -o PreferredAuthentications=password \
         -o PubkeyAuthentication=no -o ConnectTimeout=15 -o ServerAliveInterval=15)
SSHRUN() { sshpass -p "${ROOT_PASS}" ssh "${SSHOPTS[@]}" root@"${TARGET_IP}" "$@"; }
ROOT_PASS="${HAMID_PASSWORD:?HAMID_PASSWORD تنظیم نشده است}"
SSH_OK=0
for attempt in $(seq 1 12); do
  if SSHRUN 'echo OK' 2>/dev/null | grep -q OK; then SSH_OK=1; break; fi
  echo "[backup] waiting ssh ($attempt)"; sleep 6
done
if [ "$SSH_OK" != "1" ]; then
  echo "[backup] SSH FAILED"
  curl -fsS -m 20 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${NOTIFY_CHAT_ID}" --data-urlencode "text=سیستم ${VPS_NAME} قطع شد ❌
(بکاپ نگرفت: ورود SSH برقرار نشد)" >/dev/null 2>&1 || true
  exit 1
fi
echo "[backup] ssh auth OK (single secret: HAMID_PASSWORD)"
SSH() { SSHRUN "$@"; }

SSH 'cat > /tmp/bkbuild.sh' <<'REMOTE'
set -u
B=/tmp/bkbuild; rm -rf "$B"; mkdir -p "$B"
MAN="$B/manifest.txt"; : > "$MAN"
add() { printf '  %s\n' "$1" >> "$MAN"; }
BUDGET=$((36000 * 1024))
total=0
try_tar() {
  out="$B/$1"; shift
  want=0
  for p in "$@"; do [ -e "$p" ] && want=$((want + $(du -sk "$p" 2>/dev/null | awk '{print $1}'))) ; done
  if [ "$((total + want*1024))" -gt "$BUDGET" ]; then add "SKIP $1 (حجم زیاد)"; return 0; fi
  tar -czf "$out" --ignore-failed-read "$@" 2>/dev/null || return 0
  [ -s "$out" ] || return 0
  total=$((total + $(stat -c%s "$out")))
  add "$1 ($(du -h "$out" | cut -f1))"
}
if [ -f /etc/x-ui/x-ui.db ]; then
  if sqlite3 /etc/x-ui/x-ui.db "VACUUM INTO '$B/x-ui.db'" 2>/dev/null || cp -f /etc/x-ui/x-ui.db "$B/x-ui.db" 2>/dev/null; then
    total=$((total + $(stat -c%s "$B/x-ui.db"))); add "x-ui.db ($(du -h "$B/x-ui.db" | cut -f1))"
  fi
fi
if command -v mysqldump >/dev/null 2>&1; then
  if mysqldump --single-transaction --all-databases 2>/dev/null | gzip -6 > "$B/mysql-all.sql.gz"; then
    [ -s "$B/mysql-all.sql.gz" ] && { total=$((total + $(stat -c%s "$B/mysql-all.sql.gz"))); add "mysql-all.sql.gz ($(du -h "$B/mysql-all.sql.gz" | cut -f1))"; }
  else
    add "SKIP mysql (دسترسی نبود)"
  fi
fi
try_tar app-code.tar.gz /opt/9router /root/9router /opt/hermes /root/.hermes /var/www
try_tar services.tar.gz /etc/nginx /etc/cron.d /etc/systemd/system
try_tar bin-scripts.tar.gz /usr/local/bin /usr/local/sbin
try_tar home-root.tar.gz /root
{
  echo "host: $(hostname)"; echo "date: $(date -u +%FT%TZ)"; echo "uptime: $(uptime -p 2>/dev/null)"
  echo "--- running services ---"; systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '{print $1}' | head -25
  echo "--- disk ---"; df -h / | tail -1
  echo "--- tailscale ---"; tailscale ip -4 2>/dev/null | head -2
  echo "--- manifest ---"; cat "$MAN" 2>/dev/null
} > "$B/info.txt" 2>/dev/null
OUT=/tmp/$(hostname)-backup-$(date -u +%Y%m%d-%H%M).tar.gz
tar -czf "$OUT" -C "$B" .
rm -rf "$B"
echo "BACKUP_FILE=$OUT"
stat -c 'SIZE=%s' "$OUT"
REMOTE

RES="$(SSH 'bash /tmp/bkbuild.sh 2>&1 | tail -6')"
echo "[backup] remote: $(printf '%s' "$RES" | tr '\n' ' ')"
OUT="$(printf '%s' "$RES" | sed -n 's/^BACKUP_FILE=//p' | tail -1)"
[ -n "$OUT" ] || { echo "[backup] build failed"; exit 1; }

sshpass -p "${ROOT_PASS}" scp "${SSHOPTS[@]}" "root@${TARGET_IP}:${OUT}" /tmp/server-backup.tar.gz >/dev/null 2>&1 \
  || { echo "[backup] scp failed"; exit 1; }
SSH "rm -f ${OUT} /tmp/bkbuild.sh" >/dev/null 2>&1 || true

# ---------- ۲) ادغام: بکاپ سرور + بوت‌استرپ ----------
M=/tmp/merge; rm -rf "$M"; mkdir -p "$M"
tar -xzf /tmp/server-backup.tar.gz -C "$M" 2>/dev/null || true
cp -r "$BK" "$M/bootstrap"
{ echo "== محتویات =="; echo "server files:"; ls -1 "$M" | sed 's/^/  /';
  echo "bootstrap:"; ls -1 "$M/bootstrap" "$M/bootstrap/recovery" 2>/dev/null | sed 's/^/  /'; } >> "$M/bootstrap/manifest.txt"
tar -czf /tmp/final-backup.tar.gz -C "$M" .
LOCAL_SIZE=$(stat -c%s /tmp/final-backup.tar.gz)
echo "[backup] final bundle size = ${LOCAL_SIZE} bytes"

send_doc() {
  curl -fsS -m 300 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
    -F "chat_id=${NOTIFY_CHAT_ID}" -F "document=@$1" -F "caption=$2" >/dev/null 2>&1
}
CAP="🗄 بکاپ کامل سیستم ${VPS_NAME} — $(date -u '+%Y-%m-%d %H:%M') UTC
شامل: دادهٔ سرور + کل ریپو + کلیدها (Base64) + راهنمای RECOVERY"
if [ "$LOCAL_SIZE" -le "$LIMIT" ]; then
  send_doc /tmp/final-backup.tar.gz "${CAP}" && echo "[backup] sent to telegram" || echo "[backup] WARN: telegram send failed"
else
  split -b "$PART" -d -a 2 /tmp/final-backup.tar.gz /tmp/bk-part-
  n=$(ls /tmp/bk-part-* | wc -l); i=0
  for f in /tmp/bk-part-*; do i=$((i+1)); send_doc "$f" "${CAP} — بخش ${i}/${n}" && echo "[backup] part ${i}/${n} sent" || echo "[backup] WARN: part ${i} failed"; done
fi

# ---------- ۳) حالت DR: ارسال اسنپ‌شات state ----------
if [ "$DR_MODE" = "true" ]; then
  echo "[backup] DR mode: downloading state snapshot"
  TOKX="${STATE_TOKEN:-${PERSIST_TOKEN:-}}"
  if [ -n "$TOKX" ] && [ -n "${STATE_REPO:-}" ]; then
    ASSET_URL=$(curl -sS -m 60 -H "Authorization: token ${TOKX}" -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${STATE_REPO}/releases/tags/state" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); a=sorted(d.get("assets",[]), key=lambda x:x["updated_at"]); print(a[-1]["url"] if a else "")' 2>/dev/null)
    if [ -n "$ASSET_URL" ]; then
      curl -sSL -m 900 -H "Authorization: token ${TOKX}" -H "Accept: application/octet-stream" "$ASSET_URL" -o /tmp/state.tar.gz \
        && echo "[backup] state size=$(stat -c%s /tmp/state.tar.gz)"
      if [ -s /tmp/state.tar.gz ]; then
        split -b "$PART" -d -a 2 /tmp/state.tar.gz /tmp/state.part-
        n=$(ls /tmp/state.part-* | wc -l); i=0
        for f in /tmp/state.part-*; do
          i=$((i+1))
          send_doc "$f" "🧩 اسنپ‌شات state سیستم ${VPS_NAME} — بخش ${i}/${n} (${n} بخش؛ برای استفاده: cat state.part-* > state.tar.gz)" \
            && echo "[backup] state part ${i}/${n} sent" || echo "[backup] WARN: state part ${i} failed"
        done
      fi
    else
      echo "[backup] WARN: state asset not found"
    fi
  else
    echo "[backup] WARN: no token/state repo for DR"
  fi
fi
echo "[backup] done"
