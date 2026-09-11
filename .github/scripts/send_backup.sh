#!/bin/bash
# send_backup.sh (hrgh3d) — بکاپ فشردهٔ سرور و ارسال به تلگرام
# env: REPO, VPS_NAME, TARGET_IP, SSH_PASS, TAILSCALE_AUTH_KEY, TELEGRAM_BOT_TOKEN, NOTIFY_CHAT_ID
set -uo pipefail

VPS_NAME="${VPS_NAME:-$(basename "${REPO:-vps}")}"
TS_HOSTNAME="${TS_HOSTNAME:-hrg-backup}"
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
SSH() { sshpass -p "${SSH_PASS}" ssh "${SSHOPTS[@]}" root@"${TARGET_IP}" "$@"; }
for i in $(seq 1 24); do SSH 'echo OK' 2>/dev/null | grep -q OK && break || { echo "[backup] waiting ssh ($i)"; sleep 5; }; done
if ! SSH 'echo OK' >/dev/null 2>&1; then
  echo "[backup] SSH FAILED"
  curl -fsS -m 20 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${NOTIFY_CHAT_ID}" --data-urlencode "text=سیستم ${VPS_NAME} قطع شد ❌
(بکاپ نگرفت: سرور از طریق tailscale جواب نداد)" >/dev/null 2>&1 || true
  exit 1
fi

REMOTE_SCRIPT='
set -u
B=/tmp/bkbuild; rm -rf "$B"; mkdir -p "$B"
MAN="$B/manifest.txt"; : > "$MAN"
BUDGET=$((38 * 1024 * 1024))
total=0
note() { echo "  $1" >> "$MAN"; }
try_tar() {  # try_tar <outname> <path...>
  local out="$B/$1"; shift
  local want=0
  for p in "$@"; do [ -e "$p" ] && want=$((want + $(du -sk "$p" 2>/dev/null | awk "{print \$1}"))) ; done
  if [ "$((total + want*1024))" -gt "$BUDGET" ]; then note "SKIP $1 (حجم زیاد: $((want/1024))MB)"; return 0; fi
  tar -czf "$out" --ignore-failed-read "$@" 2>/dev/null || return 0
  [ -s "$out" ] || return 0
  total=$((total + $(stat -c%s "$out")))
  note "OK $1 ($(( $(stat -c%s "$out") /1024 ))KB)"
}
{ echo "host: $(hostname)"; echo "date: $(date -u +%FT%TZ)"; echo "uptime: $(uptime -p 2>/dev/null)";
  echo "--- services ---"; systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk "{print \$1}" | head -25;
  echo "--- disk ---"; df -h / | tail -1;
  echo "--- tailscale ---"; tailscale ip -4 2>/dev/null | head -2 } > "$B/info.txt" 2>/dev/null
note "OK info.txt"
# دیتابیس‌ها (اگر مای‌اس‌کیوال بود)
if command -v mysqldump >/dev/null 2>&1; then
  if mysqldump --single-transaction --all-databases > "$B/mysql-all.sql" 2>/dev/null; then
    gzip -6 "$B/mysql-all.sql" && total=$((total + $(stat -c%s "$B/mysql-all.sql.gz"))) && note "OK mysql-all.sql.gz ($(( $(stat -c%s "$B/mysql-all.sql.gz") /1024 ))KB)"
  else
    note "SKIP mysql (اتصال/دسترسی نبود)"
  fi
fi
# دیتابیس‌های sqlite شناخته‌شده
sqlite_snap() { local src="$1" dst="$2"; [ -f "$src" ] || return 0
  if sqlite3 "$src" "VACUUM INTO '\''$dst'\''" 2>/dev/null || cp -f "$src" "$dst" 2>/dev/null; then
    total=$((total + $(stat -c%s "$dst"))); note "OK $dst ($(( $(stat -c%s "$dst") /1024 ))KB)"; fi; }
sqlite_snap /etc/x-ui/x-ui.db "$B/x-ui.db"
# پوشه‌های مهم (با بودجهٔ حجمی)
try_tar app-code.tar.gz /opt/9router /root/9router /opt/hermes /root/.hermes /var/www
try_tar services.tar.gz /etc/nginx /etc/cron.d /etc/systemd/system
try_tar bin-scripts.tar.gz /usr/local/bin /usr/local/sbin /root/*.sh
try_tar home-root.tar.gz /root
OUT=/tmp/$(hostname)-backup-$(date -u +%Y%m%d-%H%M).tar.gz
tar -czf "$OUT" -C "$B" . ; rm -rf "$B"
echo "BACKUP_FILE=$OUT"; ls -l "$OUT" | awk "{print \"SIZE=\"\$5}"
'
RES="$(SSH "$REMOTE_SCRIPT" 2>&1 | tail -5)"
echo "[backup] remote: $(echo "$RES" | tr '\n' ' ')"
OUT="$(echo "$RES" | sed -n 's/^BACKUP_FILE=//p' | tail -1)"
[ -n "$OUT" ] || { echo "[backup] build failed"; exit 1; }

sshpass -p "${SSH_PASS}" scp "${SSHOPTS[@]}" "root@${TARGET_IP}:${OUT}" /tmp/backup.tar.gz >/dev/null 2>&1 || { echo "[backup] scp failed"; exit 1; }
LOCAL_SIZE=$(stat -c%s /tmp/backup.tar.gz 2>/dev/null || echo 0)
echo "[backup] local size = ${LOCAL_SIZE} bytes"
send_doc() { curl -fsS -m 240 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
    -F "chat_id=${NOTIFY_CHAT_ID}" -F "document=@$1" -F "caption=$2" >/dev/null 2>&1; }
CAP="🗄 بکاپ سیستم ${VPS_NAME} — $(date -u '+%Y-%m-%d %H:%M') UTC"
if [ "$LOCAL_SIZE" -le "$LIMIT" ]; then
  send_doc /tmp/backup.tar.gz "${CAP}" && echo "[backup] sent to telegram" || echo "[backup] WARN: telegram send failed"
else
  split -b 40m -d -a 1 /tmp/backup.tar.gz /tmp/bk-part-
  i=0; for f in /tmp/bk-part-*; do i=$((i+1)); send_doc "$f" "${CAP} (قسمت ${i})" && echo "[backup] part ${i} sent" || echo "[backup] WARN: part ${i} failed"; done
fi
SSH "rm -f ${OUT}" >/dev/null 2>&1 || true
echo "[backup] done"
