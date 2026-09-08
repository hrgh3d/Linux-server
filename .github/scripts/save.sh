#!/bin/bash
# ============================================================================
# save.sh — ساخت اسنپ‌شات وضعیت پایدار سرور و همگام‌سازی امن با مخزن state.
#
# ویژگی‌های v4:
#  - ساخت آرشیو یکتا؛ آپلود فقط وقتی محتوا واقعاً تغییر کرده باشد
#    (state_sync.py سمت ریموت را با sha256 مقایسه می‌کند).
#  - نشانگر (marker) فقط وقتی Run عوض شود به‌روزرسانی می‌شود تا در سیستمِ
#    بدون تغییر، آپلود تکراری رخ ندهد.
#  - همه‌ی مراحل خطاپذیر لاگ می‌شوند و با یک تلاش مجدد کوتاه همراه‌اند.
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/common.sh"

WORK="/tmp/persist-work"
RUN_INFO="run_id=${GITHUB_RUN_ID:-local} run_attempt=${GITHUB_RUN_ATTEMPT:-1} boot_ts=${BOOT_TS:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"

log "Starting persistent state snapshot..."

sudo rm -rf "$WORK"
mkdir -p "$WORK"

# 1) لیست پکیج‌ها
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

# 2) نشانگر ماندگاری — فقط وقتی Run عوض شده باشد (جلوگیری از آپلود تکراری)
CUR_MARKER=""
[ -f /home/Hamid/persist-marker.txt ] && CUR_MARKER="$(cat /home/Hamid/persist-marker.txt 2>/dev/null || true)"
if [ -d /home/Hamid ] && ! echo "$CUR_MARKER" | grep -q "run_id=${GITHUB_RUN_ID:-local}"; then
  echo "$RUN_INFO saved_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" | \
    sudo tee /home/Hamid/persist-marker.txt >/dev/null
  sudo chown Hamid:Hamid /home/Hamid/persist-marker.txt 2>/dev/null || true
fi
if [ -d /root ]; then
  if [ ! -f /root/persist-marker.txt ] || ! grep -q "run_id=${GITHUB_RUN_ID:-local}" /root/persist-marker.txt 2>/dev/null; then
    echo "$RUN_INFO saved_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" | \
      sudo tee /root/persist-marker.txt >/dev/null
  fi
fi

# 3) کپی مسیرهای persist.list به استیجینگ
ETC_EXCLUDES=(
  --exclude='.cache'
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
  --exclude='ssh/ssh_host_*'
  --exclude='ssh/sshd_config.d'
)

# کلیدهای Host باید جداگانه و همیشه ذخیره شوند تا تغییر نکنند.
SSH_HOST_KEYS_DIR="$WORK/etc/ssh"
mkdir -p "$SSH_HOST_KEYS_DIR"

GEN_EXCLUDES=(
  --exclude='.cache'
  --exclude='__pycache__'
  --exclude='*.pyc'
  --exclude='hostedtoolcache'
  --exclude='containerd'
  --exclude='.npm'
  --exclude='.nvm'
  --exclude='.bun'
  --exclude='.rustup'
  --exclude='.cargo'
  --exclude='go'
  --exclude='.local/share/Trash'
  --exclude='.bash_history'
  --exclude='.zsh_history'
  --exclude='core'
)

while IFS= read -r p; do
  [ -n "$p" ] || continue
  case "$p" in \#*) continue ;; esac
  rel="${p#/}"
  if [ -d "$p" ]; then
    sudo mkdir -p "$WORK/$rel"
    if [ "$p" = "/etc" ]; then
      sudo rsync -a --delete "${ETC_EXCLUDES[@]}" "$p/" "$WORK/$rel/" 2>/dev/null || true
    elif [ "$p" = "/var/lib/tailscale" ]; then
      # وضعیت Tailscale باید سالم و بدون دخالت در فایل‌های قفل‌شده کپی شود
      sudo rsync -a --exclude='*.lock' --exclude='tailscaled.sock' "$p/" "$WORK/$rel/" 2>/dev/null || true
    else
      sudo rsync -a --delete "${GEN_EXCLUDES[@]}" "$p/" "$WORK/$rel/" 2>/dev/null || true
    fi
    log "saved directory: $p"
  elif [ -f "$p" ]; then
    sudo mkdir -p "$WORK/$(dirname "$rel")"
    sudo cp -a "$p" "$WORK/$rel" 2>/dev/null || true
    log "saved file: $p"
  fi
done < "$SCRIPT_DIR/persist.list"

# کلیدهای Host SSH (در persist.list مسیر /etc هست ولی ssh_host_* کنار گذاشته شده)
if ls /etc/ssh/ssh_host_* >/dev/null 2>&1; then
  sudo cp -a /etc/ssh/ssh_host_* "$SSH_HOST_KEYS_DIR/" 2>/dev/null || true
fi

# 4) ساخت آرشیو با حفظ مالکیت واقعی فایل‌ها (sudo tar)
sudo rm -f /tmp/state.tar.gz
sudo tar -czf /tmp/state.tar.gz -C "$WORK" .
# فایل آرشیو باید برای state_sync (که با کاربر عادی اجرا می‌شود) خوانا باشد
sudo chown "$(id -u):$(id -g)" /tmp/state.tar.gz 2>/dev/null || true
ARCHIVE_SIZE=$(du -h /tmp/state.tar.gz | cut -f1)
DIGEST=$(sha256sum /tmp/state.tar.gz | cut -d' ' -f1)
log "Archive created: ${ARCHIVE_SIZE} sha256=${DIGEST:0:16}..."

# 5) آپلود / رد شدن در صورت عدم تغییر (با الگوی امن در برابر errexit)
if upload_state /tmp/state.tar.gz; then
  STATUS=0
else
  STATUS=$?
  log "ERROR: state upload failed (will be retried on next sync / final save)"
fi
if [ $STATUS -ne 0 ]; then
  log "ERROR: state upload failed (will be retried on next sync / final save)"
fi

sudo rm -rf "$WORK" /tmp/state.tar.gz
log "State snapshot attempt finished (exit=$STATUS)"
exit $STATUS
