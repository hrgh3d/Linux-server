#!/bin/bash
# ============================================================================
# restore.sh (v5)
#
#   restore.sh            -> آماده‌سازی: دانلود state، استخراج، بازنصب پکیج‌های
#                            کاتالوگ (apt/npm/pip) — code پکیج‌ها دوباره نصب می‌شود.
#   restore.sh apply      -> اعمال لایه‌ی داده/تنظیمات (payload) روی سیستم.
#
# ترتیب منطقی در Boot:  restore(prep) → provision(اپ‌های سفارشی) → restore(apply)
# تا ابتدا خودِ پکیج‌ها نصب شوند و سپس کانفیگ/دیتای ذخیره‌شده روی آن‌ها بنشیند.
# ============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/common.sh"

RESTORE=/tmp/persist-restore
MODE="${1:-prep}"

# ------------------------------------------------------------------ PREP
if [ "$MODE" = "prep" ] || [ "$MODE" = "" ]; then
  sudo rm -rf "$RESTORE" /tmp/state.tar.gz
  sudo mkdir -p "$RESTORE"
  sudo chown "$(id -u):$(id -g)" "$RESTORE"

  log "Checking for saved state archive..."
  if ! download_state /tmp/state.tar.gz; then
    log "No saved state (first run) — fresh boot."
    exit 0
  fi
  if ! gzip -t /tmp/state.tar.gz 2>/dev/null; then
    log "ERROR: archive corrupt — continuing fresh."
    exit 0
  fi
  log "Extracting state..."
  sudo tar -xzf /tmp/state.tar.gz -C "$RESTORE" 2>/dev/null || true

  # ---------------- بازنصب پکیج‌ها از کاتالوگ
  if [ -f "$RESTORE/_meta/installed.json" ]; then
    log "Package catalog found — reinstalling user packages..."
    timeout 300 sudo apt-get update -y -o DPkg::Lock::Timeout=120 >/dev/null 2>&1 || true
    # apt
    APT=()
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      case "$p" in tailscale|tailscale-archive-keyring|\#*) continue ;; esac
      dpkg -s "$p" >/dev/null 2>&1 || APT+=("$p")
    done < <(python3 -c "import json;print('\n'.join(json.load(open('$RESTORE/_meta/installed.json')).get('apt',[])))" 2>/dev/null)
    if [ "${#APT[@]}" -gt 0 ]; then
      log "apt reinstall: ${APT[*]}"
      timeout 900 sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -o DPkg::Lock::Timeout=120 "${APT[@]}" >/dev/null 2>&1 \
        && log "apt reinstall OK" || log "WARN: apt reinstall had failures"
    fi
    # npm
    NPM=()
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      case "$p" in \#*) continue ;; esac
      NPM+=("$p")
    done < <(python3 -c "import json;print('\n'.join(json.load(open('$RESTORE/_meta/installed.json')).get('npm',[])))" 2>/dev/null)
    if [ "${#NPM[@]}" -gt 0 ] && command -v npm >/dev/null 2>&1; then
      log "npm reinstall: ${NPM[*]}"
      timeout 600 npm install -g "${NPM[@]}" >/dev/null 2>&1 && log "npm reinstall OK" || log "WARN: npm reinstall failed"
    fi
    # pip
    PIP=()
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      PIP+=("$p")
    done < <(python3 -c "import json;print('\n'.join(json.load(open('$RESTORE/_meta/installed.json')).get('pip',[])))" 2>/dev/null)
    if [ "${#PIP[@]}" -gt 0 ] && command -v pip3 >/dev/null 2>&1; then
      log "pip reinstall: ${PIP[*]}"
      timeout 600 pip3 install --break-system-packages "${PIP[@]}" >/dev/null 2>&1 && log "pip reinstall OK" || log "WARN: pip reinstall failed"
    fi
    log "Catalog reinstall finished."
  else
    log "No catalog (older state) — app installers will handle provision."
  fi
  log "Restore prep done (extracted at $RESTORE)."
  exit 0
fi

# ------------------------------------------------------------------ APPLY
if [ "$MODE" = "apply" ]; then
  if [ ! -d "$RESTORE" ]; then
    log "Nothing staged to apply (fresh boot)."
    exit 0
  fi
  log "Applying restored data/config payload..."
  # اگر پنل x-ui از state بازگردانی می‌شود، سرویس را موقتاً متوقف می‌کنیم تا
  # دیتابیس/تنظیمات امن جایگزین شود و بعد دوباره بالا بیاید.
  if [ -d "$RESTORE/etc/x-ui" ]; then
    sudo systemctl stop x-ui >/dev/null 2>&1 || true
  fi

  # rsync ادغامی (بدون --delete تا فایل‌های image دست‌نخورده بمانند)
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    case "$root" in \#*) continue ;; esac
    rel="${root#/}"
    if [ -d "$RESTORE/$rel" ]; then
      sudo mkdir -p "/$rel"
      sudo rsync -a "$RESTORE/$rel/" "/$rel/" 2>/dev/null || log "warn: rsync $rel"
    fi
  done < "$SCRIPT_DIR/persist.list"

  # نرمال‌سازی مالکیت/مجوزهای حساس
  sudo chown -R 0:0 /root 2>/dev/null || true
  sudo chmod 700 /root 2>/dev/null || true
  if ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
    sudo chown root:root /etc/ssh/ssh_host_* 2>/dev/null || true
    sudo chmod 600 /etc/ssh/ssh_host_*_key 2>/dev/null || true
    sudo chmod 644 /etc/ssh/ssh_host_*_key.pub 2>/dev/null || true
  fi
  if [ -d /var/lib/tailscale ]; then
    sudo chown -R 0:0 /var/lib/tailscale 2>/dev/null || true
    sudo chmod 700 /var/lib/tailscale 2>/dev/null || true
    sudo chmod 600 /var/lib/tailscale/tailscaled.state 2>/dev/null || true
  fi
  if id Hamid >/dev/null 2>&1; then
    sudo chown -R Hamid:Hamid /home/Hamid 2>/dev/null || true
    sudo chmod 700 /home/Hamid/.ssh 2>/dev/null || true
    sudo chmod 600 /home/Hamid/.ssh/authorized_keys 2>/dev/null || true
  fi

  if [ -d "$RESTORE/etc/x-ui" ]; then
    sudo systemctl daemon-reload >/dev/null 2>&1 || true
    if ! sudo systemctl start x-ui >/dev/null 2>&1; then
      sudo nohup /usr/local/x-ui/x-ui run >/var/log/x-ui.log 2>&1 &
      sleep 1
    fi
  fi
  log "Payload applied."
  # پاک‌سازی staging نگه داشته می‌شود (تا قدم‌های بعدی مجدداً apply نکنند)
  exit 0
fi

log "unknown mode '$MODE'"
exit 2
