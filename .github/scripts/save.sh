#!/bin/bash
# ============================================================================
# save.sh — ساخت اسنپ‌شات وضعیت پایدار سرور و همگام‌سازی امن با مخزن state (v4.2)
#
# نکات طراحی:
#  - tar مستقیم از فایل‌سیستم (بدون کپی استیجینگ) => یک‌بار خواندن، سریع.
#  - فشرده‌سازی gzip -1 برای سرعت؛ لیست‌های پکیج به‌صورت فایل‌های مستقل در
#    ریشه‌ی آرشیو اضافه می‌شوند.
#  - فیلترهای حذفِ محتوای سنگین image-runner (hostedtoolcache و ...) تا حجم
#    اسنپ‌شات همیشه بسیار پایین‌تر از سقف ۲GB آپلود GitHub Release بماند.
#  - قفل (flock) برای جلوگیری از تداخل دو ذخیره‌سازی هم‌زمان.
#  - آپلود فقط در صورت تغییر sha256 (state_sync.py)؛ در غیر این صورت رد می‌شود.
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/common.sh"

LOCK=/tmp/persist-save.lock
exec 9>"$LOCK"
if ! flock -n 9; then
  log "Another save is already running — skipping this invocation."
  exit 0
fi

WORK="/tmp/persist-meta"
META="/tmp/persist-meta"
sudo rm -rf "$WORK"
mkdir -p "$WORK"

T0=$(date +%s)
log "Starting fast persistent state snapshot (direct tar)..."
phase() { echo "[persist $(date -u '+%T') +$(( $(date +%s) - T0 ))s] $*"; }

# ------------------------------------------------------------- 1) lists
if command -v dpkg &>/dev/null; then
  timeout 90 dpkg --get-selections > "$WORK/packages.list" 2>/dev/null || true
fi
if command -v apt-mark &>/dev/null; then
  timeout 60 apt-mark showmanual > "$WORK/manual_packages.list" 2>/dev/null || true
  if [ -f /tmp/base_manual_packages.list ]; then
    comm -23 <(timeout 60 apt-mark showmanual | sort) <(sort /tmp/base_manual_packages.list) \
      > "$WORK/user_packages.list" 2>/dev/null || true
  fi
fi
phase "package lists ready"

# ------------------------------------------------------------- 2) markers
RUN_INFO="run_id=${GITHUB_RUN_ID:-local} run_attempt=${GITHUB_RUN_ATTEMPT:-1} boot_ts=${BOOT_TS:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
if [ -d /home/Hamid ]; then
  if [ ! -f /home/Hamid/persist-marker.txt ] || ! grep -q "run_id=${GITHUB_RUN_ID:-local}" /home/Hamid/persist-marker.txt 2>/dev/null; then
    echo "$RUN_INFO saved_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" | \
      sudo tee /home/Hamid/persist-marker.txt >/dev/null
    sudo chown Hamid:Hamid /home/Hamid/persist-marker.txt 2>/dev/null || true
  fi
fi
if [ -d /root ]; then
  if [ ! -f /root/persist-marker.txt ] || ! grep -q "run_id=${GITHUB_RUN_ID:-local}" /root/persist-marker.txt 2>/dev/null; then
    echo "$RUN_INFO saved_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" | \
      sudo tee /root/persist-marker.txt >/dev/null
  fi
fi

# ------------------------------------------------------------- 3) excludes
# الگوهای سراسری (در همه‌ی مسیرها)
GLOBAL_EXCLUDES=(
  --exclude='.cache'
  --exclude='__pycache__'
  --exclude='*.pyc'
  --exclude='.npm'
  --exclude='.nvm'
  --exclude='.bun'
  --exclude='.rustup'
  --exclude='.cargo'
  --exclude='.bash_history'
  --exclude='.zsh_history'
  --exclude='.wget-hsts'
  --exclude='hostedtoolcache'
  --exclude='containerd'
  --exclude='core'
)
# الگوهای مختص /etc (فایل‌های گذرای میزبان/image نباید ذخیره/بازگردانی شوند)
ETC_EXCLUDES=(
  --exclude='etc/resolv.conf'
  --exclude='etc/resolvconf'
  --exclude='etc/hostname'
  --exclude='etc/hosts'
  --exclude='etc/machine-id'
  --exclude='etc/mtab'
  --exclude='etc/fstab'
  --exclude='etc/network'
  --exclude='etc/netplan'
  --exclude='etc/cloud'
  --exclude='etc/apt'
  --exclude='etc/ssl'
  --exclude='etc/alternatives'
  --exclude='etc/ld.so.cache'
  --exclude='etc/sudoers'
  --exclude='etc/sudoers.d'
  --exclude='etc/shadow*'
  --exclude='etc/gshadow*'
  --exclude='etc/passwd*'
  --exclude='etc/group*'
  --exclude='etc/subuid*'
  --exclude='etc/subgid*'
  --exclude='etc/ssh/sshd_config.d'
)

# مسیرهای انتخابی از persist.list
PATHS=()
while IFS= read -r p; do
  [ -n "$p" ] || continue
  case "$p" in \#*) continue ;; esac
  rel="${p#/}"
  if [ -d "$p" ]; then
    PATHS+=("$rel")
  fi
done < "$SCRIPT_DIR/persist.list"

# ------------------------------------------------------------- 4) tar مستقیم
phase "tar: ${PATHS[*]} ..."
sudo rm -f /tmp/state.tar.gz
set +e
sudo tar --use-compress-program='gzip -1' -cf /tmp/state.tar.gz \
  -C / "${GLOBAL_EXCLUDES[@]}" "${ETC_EXCLUDES[@]}" \
  "${PATHS[@]}" \
  -C "$META" . \
  >/tmp/tar.log 2>&1
RC=$?
set -e
if [ $RC -ne 0 ]; then
  log "ERROR: tar failed (rc=$RC): $(tail -3 /tmp/tar.log | tr '\n' ' ')"
  exit 1
fi
sudo chown "$(id -u):$(id -g)" /tmp/state.tar.gz 2>/dev/null || true
SIZE=$(stat -c%s /tmp/state.tar.gz 2>/dev/null || echo 0)
SIZEH=$(du -h /tmp/state.tar.gz | cut -f1)
DIGEST=$(sha256sum /tmp/state.tar.gz | cut -d' ' -f1)
phase "archive created: ${SIZEH} (${SIZE} bytes) sha256=${DIGEST:0:16}"

# سقف حجم GitHub Release = 2GB؛ اگر بزرگ شد خطای واضح بدهیم
if [ "$SIZE" -gt 1900000000 ]; then
  log "ERROR: archive too large (${SIZEH}) — will NOT upload. Reduce persisted paths/excludes."
  sudo rm -f /tmp/state.tar.gz
  exit 1
fi

# ------------------------------------------------------------- 5) upload (skip if unchanged)
if upload_state /tmp/state.tar.gz; then
  STATUS=0
else
  STATUS=$?
  log "ERROR: state upload failed (will be retried on next sync / final save)"
fi
sudo rm -rf "$WORK" /tmp/state.tar.gz
phase "snapshot attempt finished (exit=$STATUS)"
exit $STATUS
