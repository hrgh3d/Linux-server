#!/bin/bash
# ============================================================================
# restore.sh — بازیابی وضعیت قبلی در ابتدای هر run.
#
# ترتیب:
#   1) دانلود state.tar.gz از Release چرخشی
#   2) نصب پکیج‌ها (dpkg --set-selections + dselect-upgrade)
#   3) بازگردانی فایل‌ها (home کاربر، /root، /etc، /opt، /srv، /var/www،
#      /usr/local، cron jobs)
#
# در اولین اجرا (وقتی هنوز Release و state وجود ندارد) بدون خطا ادامه می‌دهد
# تا سرور از نو ساخته شود و در پایان، save.sh اولین state را بسازد.
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/common.sh"

RESTORE="/tmp/restore"
mkdir -p "$RESTORE"
rm -rf "$RESTORE"/* 2>/dev/null || true

if ! download_state /tmp/state.tar.gz; then
  log "first run (no saved state yet) — starting from scratch"
  exit 0
fi

tar -xzf /tmp/state.tar.gz -C "$RESTORE"
log "state extracted"

# ── نصب پکیج‌ها ──
if [ -f "$RESTORE/packages.list" ]; then
  log "refreshing apt lists"
  sudo apt-get update -y || true
  log "installing $(wc -l < "$RESTORE/packages.list") packages"
  sudo dpkg --set-selections < "$RESTORE/packages.list" || true
  sudo DEBIAN_FRONTEND=noninteractive apt-get -y dselect-upgrade \
    || log "WARNING: some packages could not be installed"
fi

# ── بازگردانی فایل‌ها ──
# فایل‌های حساس میزبان را بازنویسی نمی‌کنیم؛ بقیه‌ی /etc و سایر مسیرها بازگردانی می‌شوند.
restore_dir() {
  local rel="$1" dst="$2"
  if [ -d "$RESTORE/$rel" ]; then
    sudo mkdir -p "$dst"
    sudo rsync -a \
      --exclude='resolv.conf' --exclude='hostname' --exclude='machine-id' \
      --exclude='mtab' --exclude='fstab' --exclude='apt' --exclude='ssl' \
      --exclude='alternatives' --exclude='ld.so.cache' \
      "$RESTORE/$rel/" "$dst/" 2>/dev/null || true
    log "restored /$rel -> $dst"
  fi
}

restore_dir "etc"              "/etc"
restore_dir "home/Hamid"       "/home/Hamid"
restore_dir "root"             "/root"
restore_dir "opt"              "/opt"
restore_dir "srv"              "/srv"
restore_dir "var/www"          "/var/www"
restore_dir "usr/local"        "/usr/local"
restore_dir "var/spool/cron"   "/var/spool/cron"

# مالکیت خانهٔ کاربر (در صورت وجود کاربر)
if id Hamid &>/dev/null; then
  sudo chown -R Hamid:Hamid /home/Hamid 2>/dev/null || true
fi

# ── تأیید ماندگاری: نشانگر آخرین ذخیره‌شده از run قبلی ──
if [ -f /home/Hamid/persist-marker.txt ]; then
  log "PREVIOUS STATE MARKER: $(cat /home/Hamid/persist-marker.txt)"
else
  log "no previous marker (fresh state)"
fi

log "RESTORE COMPLETE"
