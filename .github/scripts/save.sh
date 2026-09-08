#!/bin/bash
# ============================================================================
# save.sh — ذخیره وضعیت پایدار سرور و آپلود روی Release در مخزن state.
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/common.sh"

WORK="/tmp/persist-work"
sudo rm -rf "$WORK"
mkdir -p "$WORK"

log "Starting fast state backup..."

# 1) ثبت لیست پکیج‌های نصب‌شده
if command -v dpkg &>/dev/null; then
  sudo dpkg --get-selections > "$WORK/packages.list" 2>/dev/null || true
fi
if command -v apt-mark &>/dev/null; then
  sudo apt-mark showmanual > "$WORK/manual_packages.list" 2>/dev/null || true
  if [ -f /tmp/base_manual_packages.list ]; then
    comm -23 <(sudo apt-mark showmanual | sort) <(sort /tmp/base_manual_packages.list) \
      > "$WORK/user_packages.list" 2>/dev/null || true
  fi
fi

# 2) ثبت نشانگر زمان ذخیره
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
RUN_INFO="saved_at=${TIMESTAMP} run_id=${GITHUB_RUN_ID:-local} run_attempt=${GITHUB_RUN_ATTEMPT:-1}"

if [ -d /home/Hamid ]; then
  echo "$RUN_INFO" | sudo tee /home/Hamid/persist-marker.txt >/dev/null
  sudo chown Hamid:Hamid /home/Hamid/persist-marker.txt 2>/dev/null || true
fi
if [ -d /root ]; then
  echo "$RUN_INFO" | sudo tee /root/persist-marker.txt >/dev/null
fi

# 3) کپی مسیرهای مشخص‌شده در persist.list
ETC_EXCLUDES=(
  --exclude='.cache'
  --exclude='resolv.conf'
  --exclude='hostname'
  --exclude='hosts'
  --exclude='machine-id'
  --exclude='mtab'
  --exclude='fstab'
  --exclude='network'
  --exclude='netplan'
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
  --exclude='subuid'
  --exclude='subgid'
)

GEN_EXCLUDES=(
  --exclude='.cache'
  --exclude='__pycache__'
  --exclude='hostedtoolcache'
  --exclude='containerd'
)

while IFS= read -r p; do
  [ -n "$p" ] || continue
  case "$p" in \#*) continue ;; esac
  rel="${p#/}"
  if [ -d "$p" ]; then
    sudo mkdir -p "$WORK/$rel"
    if [ "$p" = "/etc" ]; then
      sudo rsync -a "${ETC_EXCLUDES[@]}" "$p/" "$WORK/$rel/" 2>/dev/null || true
    else
      sudo rsync -a "${GEN_EXCLUDES[@]}" "$p/" "$WORK/$rel/" 2>/dev/null || true
    fi
    log "saved directory: $p"
  elif [ -f "$p" ]; then
    sudo mkdir -p "$WORK/$(dirname "$rel")"
    sudo cp -a "$p" "$WORK/$rel" 2>/dev/null || true
    log "saved file: $p"
  fi
done < "$SCRIPT_DIR/persist.list"

# 4) ساخت آرشیو tar
sudo chown -R "$(id -u):$(id -g)" "$WORK" 2>/dev/null || true
tar -czf /tmp/state.tar.gz -C "$WORK" .
ARCHIVE_SIZE=$(du -h /tmp/state.tar.gz | cut -f1)
log "Archive created: ${ARCHIVE_SIZE}"

# 5) آپلود آرشیو روی Release چرخشی
upload_state /tmp/state.tar.gz

sudo rm -rf "$WORK" /tmp/state.tar.gz
log "State backup completed successfully!"
