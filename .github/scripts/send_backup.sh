#!/bin/bash
# send_backup.sh — بکاپ فشردهٔ سرور → ارسال به ربات گزارش تلگرام
# env: REPO, VPS_NAME, TARGET_IP, SSH_PASS, HAMID_PASSWORD, TAILSCALE_AUTH_KEY,
#      TELEGRAM_BOT_TOKEN, NOTIFY_CHAT_ID
set -uo pipefail

VPS_NAME="${VPS_NAME:-$(basename "${REPO:-vps}")}"
TS_HOSTNAME="${TS_HOSTNAME:-mrp-backup}"
LIMIT=$((45 * 1024 * 1024))

echo "[backup] $(date -u +%FT%TZ) vps=${VPS_NAME} target=${TARGET_IP}"
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
# تنها منبع رمز root: سکرت HAMID_PASSWORD (SSH_PASS حذف شد تا دوگانگی پیش نیاید)
ROOT_PASS="${HAMID_PASSWORD:?HAMID_PASSWORD تنظیم نشده است}"
SSH_OK=0
for attempt in $(seq 1 12); do
  if SSHRUN 'echo OK' 2>/dev/null | grep -q OK; then SSH_OK=1; break; fi
  echo "[backup] waiting ssh ($attempt)"; sleep 6
done
if [ "$SSH_OK" != "1" ]; then
  echo "[backup] SSH FAILED (HAMID_PASSWORD accepted نشد)"
  curl -fsS -m 20 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${NOTIFY_CHAT_ID}" --data-urlencode "text=سیستم ${VPS_NAME} قطع شد ❌
(بکاپ نگرفت: ورود SSH برقرار نشد)" >/dev/null 2>&1 || true
  exit 1
fi
echo "[backup] ssh auth OK (single secret: HAMID_PASSWORD)"
SSH() { SSHRUN "$@"; }

# ---------- اسکریپت ساخت بکاپ (روی سرور hrgh3d) ----------
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

sshpass -p "${ROOT_PASS}" scp "${SSHOPTS[@]}" "root@${TARGET_IP}:${OUT}" /tmp/backup.tar.gz >/dev/null 2>&1 \
  || { echo "[backup] scp failed"; exit 1; }
LOCAL_SIZE=$(stat -c%s /tmp/backup.tar.gz 2>/dev/null || echo 0)
echo "[backup] local size = ${LOCAL_SIZE} bytes"

send_doc() {
  curl -fsS -m 240 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
    -F "chat_id=${NOTIFY_CHAT_ID}" -F "document=@$1" -F "caption=$2" >/dev/null 2>&1
}
CAP="🗄 بکاپ سیستم ${VPS_NAME} — $(date -u '+%Y-%m-%d %H:%M') UTC"
if [ "$LOCAL_SIZE" -le "$LIMIT" ]; then
  send_doc /tmp/backup.tar.gz "${CAP}" && echo "[backup] sent to telegram" || echo "[backup] WARN: telegram send failed"
else
  echo "[backup] too big (${LOCAL_SIZE}) → splitting"
  split -b 40m -d -a 1 /tmp/backup.tar.gz /tmp/bk-part-
  i=0
  for f in /tmp/bk-part-*; do
    i=$((i+1))
    send_doc "$f" "${CAP} (قسمت ${i})" && echo "[backup] part ${i} sent" || echo "[backup] WARN: part ${i} failed"
  done
fi
SSH "rm -f ${OUT} /tmp/bkbuild.sh" >/dev/null 2>&1 || true
echo "[backup] done"
