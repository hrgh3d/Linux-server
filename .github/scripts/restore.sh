#!/bin/bash
# ============================================================================
# restore.sh — بازیابی وضعیت قبلی در ابتدای اجرای سرور.
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/common.sh"

RESTORE="/tmp/restore_extract"
sudo rm -rf "$RESTORE" /tmp/state.tar.gz
mkdir -p "$RESTORE"

log "Checking for saved state archive..."

if ! download_state /tmp/state.tar.gz; then
  log "No saved state found (first run) — starting with fresh environment."
  exit 0
fi

log "Extracting persistent state archive..."
tar -xzf /tmp/state.tar.gz -C "$RESTORE"

# 1) بازیابی پکیج‌های اختصاصی نصب‌شده توسط کاربر
if [ -f "$RESTORE/user_packages.list" ] && [ -s "$RESTORE/user_packages.list" ]; then
  log "Reinstalling user-installed packages..."
  sudo apt-get update -y || true
  grep -v -E '^(#|$)' "$RESTORE/user_packages.list" | xargs -r sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends || true
fi

# 2) بازیابی دایرکتوری‌ها
restore_path() {
  local rel="$1"
  local dst="$2"
  if [ -d "$RESTORE/$rel" ]; then
    sudo mkdir -p "$dst"
    if [ "$rel" = "etc" ]; then
      sudo rsync -a \
        --exclude='resolv.conf' --exclude='hostname' --exclude='hosts' \
        --exclude='machine-id' --exclude='mtab' --exclude='fstab' \
        --exclude='network' --exclude='netplan' --exclude='apt' \
        --exclude='ssl' --exclude='alternatives' --exclude='ld.so.cache' \
        --exclude='sudoers' --exclude='sudoers.d' \
        --exclude='shadow*' --exclude='gshadow*' --exclude='passwd*' --exclude='group*' \
        --exclude='subuid' --exclude='subgid' \
        "$RESTORE/$rel/" "$dst/" 2>/dev/null || true
    else
      sudo rsync -a "$RESTORE/$rel/" "$dst/" 2>/dev/null || true
    fi
    log "Restored /$rel -> $dst"
  elif [ -f "$RESTORE/$rel" ]; then
    sudo mkdir -p "$(dirname "$dst")"
    sudo cp -a "$RESTORE/$rel" "$dst" 2>/dev/null || true
    log "Restored file /$rel -> $dst"
  fi
}

restore_path "etc"                "/etc"
restore_path "home/Hamid"         "/home/Hamid"
restore_path "root"               "/root"
restore_path "var/lib/tailscale"  "/var/lib/tailscale"
restore_path "usr/local/bin"      "/usr/local/bin"
restore_path "usr/local/sbin"     "/usr/local/sbin"
restore_path "opt"                "/opt"
restore_path "srv"                "/srv"
restore_path "var/www"            "/var/www"
restore_path "var/spool/cron"     "/var/spool/cron"

# 3) تضمین امنیت و دسترسی‌های صحیح فایل‌های سیستمی و کاربران
sudo chown 0:0 /etc/sudoers 2>/dev/null || true
sudo chmod 0440 /etc/sudoers 2>/dev/null || true
sudo chown -R 0:0 /etc/sudoers.d 2>/dev/null || true
sudo chmod 0750 /etc/sudoers.d 2>/dev/null || true
sudo chmod 0440 /etc/sudoers.d/* 2>/dev/null || true

sudo chown -R 0:0 /root 2>/dev/null || true
sudo chmod 700 /root 2>/dev/null || true

if [ -d /var/lib/tailscale ]; then
  sudo chown -R 0:0 /var/lib/tailscale 2>/dev/null || true
  sudo chmod 700 /var/lib/tailscale 2>/dev/null || true
fi

if id Hamid &>/dev/null; then
  sudo chown -R Hamid:Hamid /home/Hamid 2>/dev/null || true
  sudo chmod 700 /home/Hamid 2>/dev/null || true
  if [ -d /home/Hamid/.ssh ]; then
    sudo chmod 700 /home/Hamid/.ssh
    sudo chmod 600 /home/Hamid/.ssh/* 2>/dev/null || true
  fi
fi

# 4) بررسی و لاگ نشانگر بازیابی‌شده
if [ -f /home/Hamid/persist-marker.txt ]; then
  log "Restored state marker (Hamid): $(cat /home/Hamid/persist-marker.txt)"
elif [ -f /root/persist-marker.txt ]; then
  log "Restored state marker (root): $(cat /root/persist-marker.txt)"
else
  log "Fresh state restored (no previous marker)."
fi

sudo rm -rf "$RESTORE" /tmp/state.tar.gz
log "State restore completed successfully!"
