#!/bin/bash
# ============================================================================
# restore.sh (v5.1)
#
#   restore.sh            -> آماده‌سازی: دانلود state، بررسی سالم بودن آرشیو،
#                            استخراج، بازنصب پکیج‌های کاتالوگ با «نسخهٔ دقیق»
#                            (apt name=ver / npm name@ver / pip name==ver) و در
#                            صورت نبودِ نسخه، fallback به آخرین نسخه با WARN.
#   restore.sh apply      -> اعمال لایه‌ی داده/تنظیمات (payload) روی سیستم.
#
# ترتیب منطقی در Boot:  restore(prep) → provision(اپ‌های سفارشی) → restore(apply)
# ============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/common.sh"

RESTORE=/tmp/persist-restore
MODE="${1:-prep}"
INSTALLED="$RESTORE/_meta/installed.json"

log() { echo "[persist $(date -u '+%T')] $*"; }

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
  # بررسی سالم بودن آرشیو پیش از استخراج (قبل از هر چیز)
  if ! gzip -t /tmp/state.tar.gz 2>/dev/null; then
    log "ERROR: state archive corrupt (gzip) — continuing fresh."
    bash "$SCRIPT_DIR/notify.sh" --type restore --stage download \
      --error "state archive failed gzip integrity test" || true
    sudo rm -f /tmp/state.tar.gz
    exit 0
  fi
  if ! tar -tzf /tmp/state.tar.gz >/dev/null 2>&1; then
    log "ERROR: state archive cannot be listed (tar) — continuing fresh."
    bash "$SCRIPT_DIR/notify.sh" --type restore --stage download \
      --error "state archive cannot be listed with tar -tzf" || true
    sudo rm -f /tmp/state.tar.gz
    exit 0
  fi

  log "Extracting state..."
  if ! sudo tar -xzf /tmp/state.tar.gz -C "$RESTORE" 2>/tmp/restore-extract.log; then
    log "ERROR: state extraction failed — continuing fresh (previous state not usable)."
    tail -5 /tmp/restore-extract.log 2>/dev/null | sed 's/^/    /'
    bash "$SCRIPT_DIR/notify.sh" --type restore --stage extract \
      --error "state extraction failed: $(tail -2 /tmp/restore-extract.log 2>/dev/null | tr '\n' ' ')" || true
    sudo rm -rf "$RESTORE"
    exit 0
  fi
  if [ ! -f "$INSTALLED" ]; then
    log "No catalog in state (older v4/v5 state) — app installers will handle provision."
    log "Restore prep done (extracted at $RESTORE, no catalog)."
    exit 0
  fi

  # ---------------- بازنصب پکیج‌ها از کاتالوگ (نسخه‌دار)
  log "Package catalog found — reinstalling user packages (exact versions)..."
  timeout 300 sudo apt-get update -y -o DPkg::Lock::Timeout=120 >/dev/null 2>&1 || true

  norm() { # چاپ spec،name,ver برای هر ورودی؛ پشتیبانی از قالب قدیمی (فقط نام)
    python3 - "$1" "$INSTALLED" <<'PY'
import json, sys
kind, path = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(path))
except Exception:
    sys.exit(0)
entries = d.get(kind, []) or []
out = []
for e in entries:
    e = (e or "").strip()
    if not e or e.startswith("#"):
        continue
    name, ver = e, ""
    if kind == "apt":
        if "=" in e:
            name, ver = e.split("=", 1)
        if name in ("tailscale", "tailscale-archive-keyring"):
            continue
    elif kind == "npm":
        if e.startswith("@"):
            i = e.rfind("@")
            if i > 1:                 # scoped with version: @scope/name@1.2.3
                name, ver = e[:i], e[i + 1:]
        else:
            if "@" in e:
                name, ver = e.rsplit("@", 1)
    else:  # pip
        if "==" in e:
            name, ver = e.split("==", 1)
    out.append((e, name, ver))
for spec, name, ver in out:
    print("%s\t%s\t%s" % (spec, name, ver))
PY
  }

  is_installed() {
    dpkg -s "$1" >/dev/null 2>&1 || return 1
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
  }

  apt_fail=0; npm_fail=0; pip_fail=0

  # --- apt ---
  APT_N=0
  while IFS=$'\t' read -r spec name ver; do
    [ -n "$name" ] || continue
    if is_installed "$name"; then
      log "apt skip (installed): $name"
      continue
    fi
    APT_N=$((APT_N + 1))
    log "apt install: ${spec}${ver:+  (pin $name=$ver)}"
    if [ -n "$ver" ]; then
      if DEBIAN_FRONTEND=noninteractive timeout 300 apt-get install -y \
           -o DPkg::Lock::Timeout=120 "$name=$ver" >/tmp/apt-install.log 2>&1; then
        log "apt OK: $name=$ver"
        continue
      fi
      log "WARN: apt $name=$ver failed — falling back to latest"
    fi
    if DEBIAN_FRONTEND=noninteractive timeout 300 apt-get install -y \
         -o DPkg::Lock::Timeout=120 "$name" >/tmp/apt-install.log 2>&1; then
      log "apt OK (latest): $name"
    else
      log "FAIL apt: $name ($(tail -2 /tmp/apt-install.log 2>/dev/null | tr '\n' ' '))"
      apt_fail=1
    fi
  done < <(norm apt)
  [ "$APT_N" -gt 0 ] && log "apt reinstall done ($APT_N pkg(s))"

  # --- npm ---
  if command -v npm >/dev/null 2>&1; then
    NPM_N=0
    while IFS=$'\t' read -r spec name ver; do
      [ -n "$name" ] || continue
      NPM_N=$((NPM_N + 1))
      log "npm install: $spec"
      if timeout 300 npm install -g "$spec" >/tmp/npm-install.log 2>&1; then
        log "npm OK: $spec"
        continue
      fi
      if [ -n "$ver" ] && [ "$spec" != "$name" ]; then
        log "WARN: npm $spec failed — retrying with plain name"
        if timeout 300 npm install -g "$name" >/tmp/npm-install.log 2>&1; then
          log "npm OK (latest): $name"
          continue
        fi
      fi
      log "FAIL npm: $spec ($(tail -2 /tmp/npm-install.log 2>/dev/null | tr '\n' ' '))"
      npm_fail=1
    done < <(norm npm)
    [ "$NPM_N" -gt 0 ] && log "npm reinstall done ($NPM_N pkg(s))"
  fi

  # --- pip ---
  if command -v pip3 >/dev/null 2>&1; then
    PIP_N=0
    while IFS=$'\t' read -r spec name ver; do
      [ -n "$name" ] || continue
      PIP_N=$((PIP_N + 1))
      log "pip install: $spec"
      if timeout 300 pip3 install --break-system-packages "$spec" >/tmp/pip-install.log 2>&1; then
        log "pip OK: $spec"
        continue
      fi
      if [ -n "$ver" ] && [ "$spec" != "$name" ]; then
        log "WARN: pip $spec failed — retrying with plain name"
        if timeout 300 pip3 install --break-system-packages "$name" >/tmp/pip-install.log 2>&1; then
          log "pip OK (latest): $name"
          continue
        fi
      fi
      log "FAIL pip: $spec ($(tail -2 /tmp/pip-install.log 2>/dev/null | tr '\n' ' '))"
      pip_fail=1
    done < <(norm pip)
    [ "$PIP_N" -gt 0 ] && log "pip reinstall done ($PIP_N pkg(s))"
  fi

  if [ "$apt_fail" -ne 0 ] || [ "$npm_fail" -ne 0 ] || [ "$pip_fail" -ne 0 ]; then
    log "WARN: catalog reinstall had partial failures (apt=$apt_fail npm=$npm_fail pip=$pip_fail)"
    # این یک خطای «واقعی» است: کاتالوگ کامل بازیابی نشد؛ اطلاع‌رسانی می‌شود ولی
    # Boot ادامه می‌یابد تا provision اپ‌های اصلی را نصب کند.
    bash "$SCRIPT_DIR/notify.sh" --type restore --stage catalog-reinstall \
      --error "partial catalog reinstall failure apt=$apt_fail npm=$npm_fail pip=$pip_fail" || true
  else
    log "Catalog reinstall finished OK."
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
  exit 0
fi

log "unknown mode '$MODE'"
exit 2
