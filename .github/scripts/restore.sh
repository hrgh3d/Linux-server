#!/bin/bash
# ============================================================================
# restore.sh — بازیابی وضعیت پایدار در ابتدای هر چرخه‌ی جدید سرور. (v4)
#
#  - دانلود جدیدترین state از مخزن state و اعتبارسنجی آرشیو
#  - استخراج با sudo برای حفظ مالکیت/مجوزهای واقعی فایل‌ها
#  - بازنصب پکیج‌های کاربر (user_packages.list)
#  - rsync مسیرهای ماندگار با فیلترهای امن (بدون دست‌زدن به هویت runner)
#  - نرمال‌سازی مالکیت مسیرهای حیاتی (home/root/tailscale/ssh)
# ============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/common.sh"

RESTORE="/tmp/persist-restore"
sudo rm -rf "$RESTORE" /tmp/state.tar.gz
sudo mkdir -p "$RESTORE"
sudo chown "$(id -u):$(id -g)" "$RESTORE"

log "Checking for saved state archive..."

if ! download_state /tmp/state.tar.gz; then
  log "No saved state found (first run) — starting fresh; base packages already installed."
  exit 0
fi

# اعتبارسنجی سریع آرشیو
if ! gzip -t /tmp/state.tar.gz 2>/dev/null; then
  log "ERROR: downloaded archive is corrupt — refusing restore (continuing fresh)."
  exit 0
fi

log "Extracting persistent state archive (preserving ownership)..."
sudo tar -xzf /tmp/state.tar.gz -C "$RESTORE" 2>/dev/null || {
  log "ERROR: extraction failed — continuing with fresh environment."
  exit 0
}

# ---------------------------------------------------------------- پکیج‌ها
if [ -f "$RESTORE/user_packages.list" ] && [ -s "$RESTORE/user_packages.list" ]; then
  log "Reinstalling user-installed packages..."
  (timeout 300 sudo apt-get update -y -o DPkg::Lock::Timeout=120 || true) 2>&1 | tail -2
  FAILED=0
  while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    case "$pkg" in \#*) continue ;; esac
    if ! timeout 300 sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends -o DPkg::Lock::Timeout=120 "$pkg" >/dev/null 2>&1; then
      # تلاش دوم
      if ! timeout 300 sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends -o DPkg::Lock::Timeout=120 "$pkg" >/dev/null 2>&1; then
        log "WARN: could not reinstall package '$pkg' (will retry in future cycles)"
        FAILED=$((FAILED+1))
      fi
    fi
  done < "$RESTORE/user_packages.list"
  log "Package restore finished (failed=$FAILED)"
fi

# ---------------------------------------------------------------- rsync
# فیلترهای امن برای /etc — هرگز نباید فایل‌های حیاتی runner/image بازنویسی شوند
ETC_EXCLUDES=(
  --exclude='resolv.conf'
  --exclude='resolvconf'
  --exclude='hostname'
  --exclude='hosts'
  --exclude='machine-id'
  --exclude='mtab'
  --exclude='fstab'
  --exclude='network'
  --exclude='netplan'
  --exclude='cloud'
  --exclude='apt'
  --exclude='ssl'
  --exclude='alternatives'
  --exclude='ld.so.cache'
  --exclude='sudoers'
  --exclude='sudoers.d'
  --exclude='shadow*'
  --exclude='gshadow*'
  --exclude='passwd*'
  --exclude='group*'
  --exclude='subuid*'
  --exclude='subgid*'
)

restore_path() {
  local rel="$1" dst="$2"
  if [ -d "$RESTORE/$rel" ]; then
    sudo mkdir -p "$dst"
    if [ "$rel" = "etc" ]; then
      sudo rsync -a "${ETC_EXCLUDES[@]}" "$RESTORE/$rel/" "$dst/" 2>/dev/null || true
    else
      sudo rsync -a "$RESTORE/$rel/" "$dst/" 2>/dev/null || true
    fi
    log "restored /$rel -> $dst"
  elif [ -f "$RESTORE/$rel" ]; then
    sudo mkdir -p "$(dirname "$dst")"
    sudo cp -a "$RESTORE/$rel" "$dst" 2>/dev/null || true
    log "restored file /$rel -> $dst"
  fi
}

# ترتیب مهم: هر مسیر فقط محتوای مختص خودش را بازمی‌گرداند
restore_path "home/Hamid"         "/home/Hamid"
restore_path "root"               "/root"
restore_path "var/lib/tailscale"  "/var/lib/tailscale"
restore_path "etc"                "/etc"
restore_path "usr/local/bin"      "/usr/local/bin"
restore_path "usr/local/sbin"     "/usr/local/sbin"
restore_path "opt"                "/opt"
restore_path "srv"                "/srv"
restore_path "var/www"            "/var/www"
restore_path "var/spool/cron"     "/var/spool/cron"

# ------------------------------------------------- نرمال‌سازی مالکیت/مجوزها
sudo chown 0:0 /etc/sudoers 2>/dev/null || true
sudo chmod 0440 /etc/sudoers 2>/dev/null || true
sudo chown -R 0:0 /etc/sudoers.d 2>/dev/null || true
sudo chmod 0750 /etc/sudoers.d 2>/dev/null || true

# مسیرهای سیستمی بازگردانی‌شده باید root-owned باشند
for d in /etc/ssh /usr/local/bin /usr/local/sbin /opt /srv /var/www /var/spool/cron; do
  [ -e "$d" ] && sudo chown -R 0:0 "$d" 2>/dev/null || true
done

# کلیدهای Host: ریشه و 600 (در غیر این صورت sshd از آن‌ها استفاده نمی‌کند)
if ls /etc/ssh/ssh_host_* >/dev/null 2>&1; then
  sudo chown 0:0 /etc/ssh/ssh_host_* 2>/dev/null || true
  sudo chmod 600 /etc/ssh/ssh_host_* 2>/dev/null || true
  sudo chmod 644 /etc/ssh/ssh_host_*.pub 2>/dev/null || true
  log "SSH host keys restored: $(ls /etc/ssh/ssh_host_*.pub 2>/dev/null | wc -l) keys"
fi

sudo chown -R 0:0 /root 2>/dev/null || true
sudo chmod 700 /root 2>/dev/null || true

if [ -d /var/lib/tailscale ]; then
  sudo chown -R 0:0 /var/lib/tailscale 2>/dev/null || true
  sudo chmod 700 /var/lib/tailscale 2>/dev/null || true
  sudo chmod 600 /var/lib/tailscale/tailscaled.state 2>/dev/null || true
fi

if id Hamid &>/dev/null; then
  sudo chown -R Hamid:Hamid /home/Hamid 2>/dev/null || true
  sudo chmod 700 /home/Hamid 2>/dev/null || true
  if [ -d /home/Hamid/.ssh ]; then
    sudo chmod 700 /home/Hamid/.ssh
    sudo chmod 600 /home/Hamid/.ssh/* 2>/dev/null || true
  fi
fi

# ----------------------------------------------- گزارش بازیابی
if [ -f /root/persist-marker.txt ]; then
  log "Restored /root marker: $(cat /root/persist-marker.txt)"
fi
if [ -f /home/Hamid/persist-marker.txt ]; then
  log "Restored /home/Hamid marker: $(cat /home/Hamid/persist-marker.txt)"
fi
[ -f /root/.server-state.json ] && log "Restored previous /root/.server-state.json: $(head -c 400 /root/.server-state.json)"

ROOT_COUNT=$(sudo find /root -maxdepth 1 -type f 2>/dev/null | wc -l)
HOME_COUNT=$(sudo find /home/Hamid -maxdepth 1 -type f 2>/dev/null | wc -l)
log "Restore complete (files directly in /root: $ROOT_COUNT, in /home/Hamid: $HOME_COUNT)"
sudo rm -rf "$RESTORE" /tmp/state.tar.gz
exit 0
