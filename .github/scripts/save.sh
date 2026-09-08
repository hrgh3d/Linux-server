#!/bin/bash
# ============================================================================
# save.sh — جمع‌آوری هر آنچه باید بعد از reset بماند و آپلود روی Release.
#
# چه چیزهایی ذخیره می‌شوند:
#   - لیست پکیج‌های نصب‌شده (dpkg --get-selections)
#   - مسیرهای فهرست‌شده در persist.list (خانهٔ کاربر، /root، /etc، /opt، /srv،
#     /var/www، /usr/local، cron jobs و ...)
#
# چه چیزهایی ذخیره نمی‌شوند (عمدی):
#   - /proc، /sys، /dev، /tmp و کش‌های موقت runner
#   - وضعیت runtime تِیل‌اسکیل (هر run یک node جدید می‌سازد و IP ثابت از طریق
#     Tailscale API روی همان node تثبیت می‌شود)
#   - فایل‌های حساس میزبان: resolv.conf، hostname، machine-id، fstab، mtab،
#     /etc/apt، /etc/ssl، /etc/alternatives (هر بار تازه ساخته می‌شوند)
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/common.sh"

WORK="/tmp/persist-work"
rm -rf "$WORK"
mkdir -p "$WORK"

EXCLUDES=(
  --exclude='.cache'
  --exclude='resolv.conf'
  --exclude='hostname'
  --exclude='machine-id'
  --exclude='mtab'
  --exclude='fstab'
  --exclude='apt'
  --exclude='ssl'
  --exclude='alternatives'
  --exclude='ld.so.cache'
)

# 1) لیست پکیج‌ها
sudo dpkg --get-selections > "$WORK/packages.list"
log "packages: $(wc -l < "$WORK/packages.list")"

# 2) نشانگر آخرین ذخیره — داخل state می‌رود تا در run بعدی قابل تأیید باشد
if [ -d /home/Hamid ]; then
  echo "saved_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ') run_id=${GITHUB_RUN_ID:-local}" \
    | sudo tee /home/Hamid/persist-marker.txt >/dev/null
  sudo chown Hamid:Hamid /home/Hamid/persist-marker.txt 2>/dev/null || true
  log "marker written"
fi

# 3) فایل‌ها و پوشه‌های دائمی (طبق manifest)
while IFS= read -r p; do
  [ -n "$p" ] || continue
  case "$p" in \#*) continue ;; esac
  rel="${p#/}"
  if [ -d "$p" ]; then
    mkdir -p "$WORK/$rel"
    if sudo rsync -a "${EXCLUDES[@]}" "$p/" "$WORK/$rel/" 2>/dev/null; then
      log "saved dir  $p"
    else
      log "WARN: partial save for $p"
    fi
  elif [ -f "$p" ]; then
    mkdir -p "$WORK/$(dirname "$rel")"
    if sudo cp -a "$p" "$WORK/$rel" 2>/dev/null; then
      log "saved file $p"
    else
      log "WARN: could not save $p"
    fi
  fi
done < "$SCRIPT_DIR/persist.list"

# 3) ساخت آرشیو
sudo chown -R "$(id -u):$(id -g)" "$WORK" 2>/dev/null || true
tar -czf state.tar.gz -C "$WORK" .
log "archive: $(du -h state.tar.gz | cut -f1)"

# 4) آپلود روی Release چرخشی
upload_state state.tar.gz

log "SAVE COMPLETE"
