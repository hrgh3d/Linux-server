#!/bin/bash
# ============================================================================
# provision.sh — نصب خودکار و ایدم‌پوتِ نرم‌افزارهای «کاربر» روی هر Boot (v4.4)
#   - v4.4: 3x-ui به درخواست کاربر حذف شد (دیگر نصب نمی‌شود)
#   نرم‌افزارهای تحت پوشش:
#   1) 9router            (npm global)
#   2) Hermes Agent       (installer رسمی Nous Research — غیرتعاملی)
#   3) 3x-ui              (غیرفعال شد - کاربر نیازی ندارد)
# ============================================================================
set -uo pipefail
LOG_DIR=/tmp/provision
mkdir -p "$LOG_DIR"

log()  { echo "[provision $(date -u '+%T')] $*"; }
note() { echo "[provision] $*" | tee -a "${LOG_DIR}/summary.txt"; }
: > "${LOG_DIR}/summary.txt"

SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

ensure_npm() {
  command -v npm >/dev/null 2>&1 && return 0
  command -v nodejs >/dev/null 2>&1 || $SUDO apt-get install -y -qq nodejs npm >/dev/null 2>&1 || true
  command -v npm >/dev/null 2>&1
}

provision_9router() {
  if [ -x /usr/local/bin/9router ] && [ -d /usr/local/lib/node_modules/9router ]; then
    note "9router: present (restored) — skip"
    return 0
  fi
  log "9router: not found — installing via npm..."
  if ensure_npm && timeout 300 $SUDO env PATH="$PATH" npm install -g 9router >"${LOG_DIR}/9router.log" 2>&1; then
    note "9router: INSTALLED ($($SUDO /usr/local/bin/9router --version 2>/dev/null || echo ok))"
  else
    note "9router: install FAILED (see ${LOG_DIR}/9router.log)"
  fi
}

provision_hermes() {
  if [ -x /usr/local/bin/hermes ] && [ -d /usr/local/lib/hermes-agent ]; then
    note "hermes: present (FHS restored) — skip"
    return 0
  fi
  if [ -x /root/.hermes/hermes-agent/hermes ] || [ -d /root/.hermes/hermes-agent/.git ]; then
    note "hermes: present (legacy under /root/.hermes) — skip"
    return 0
  fi
  log "hermes: not found — running official installer as root (FHS, non-interactive)..."
  curl -fsSL --max-time 60 https://hermes-agent.nousresearch.com/install.sh -o /tmp/hermes-install.sh \
    || { note "hermes: download of installer FAILED"; return 1; }
  timeout 1500 $SUDO env HERMES_HOME=/root/.hermes \
      bash /tmp/hermes-install.sh --non-interactive \
          --skip-browser --skip-computer-use \
      >"${LOG_DIR}/hermes.log" 2>&1
  rc=$?
  if [ $rc -eq 0 ] && { [ -x /usr/local/bin/hermes ] || [ -x /root/.hermes/hermes-agent/hermes ]; }; then
    note "hermes: INSTALLED (cmd=$(command -v hermes 2>/dev/null || echo /usr/local/bin/hermes))"
  else
    note "hermes: install did not complete (rc=$rc) — see ${LOG_DIR}/hermes.log"
    echo "----- tail hermes.log -----" | tee -a "${LOG_DIR}/summary.txt"
    tail -40 "${LOG_DIR}/hermes.log" 2>/dev/null | tee -a "${LOG_DIR}/summary.txt"
  fi
}

provision_xui() {
  # v4.4: 3x-ui به درخواست کاربر غیرفعال شد - هیچ کاری انجام نمی‌شود
  # اگر فایل‌های قدیمی باقی مانده باشند، آن‌ها را پاک می‌کنیم تا در بوت بعدی برنگردند
  if [ -d /etc/x-ui ] || [ -d /usr/local/x-ui ] || [ -f /etc/systemd/system/x-ui.service ]; then
    log "3x-ui: found leftover files — removing (user disabled x-ui)..."
    $SUDO systemctl stop x-ui >/dev/null 2>&1 || true
    $SUDO systemctl disable x-ui >/dev/null 2>&1 || true
    $SUDO rm -rf /etc/x-ui /usr/local/x-ui /etc/systemd/system/x-ui.service /etc/systemd/system/multi-user.target.wants/x-ui.service >/dev/null 2>&1 || true
    $SUDO systemctl daemon-reload >/dev/null 2>&1 || true
    note "3x-ui: REMOVED (user disabled)"
  else
    note "3x-ui: disabled by user — skip"
  fi
  return 0
}

log "=== provisioning start ==="
provision_9router
provision_hermes
provision_xui
log "=== provisioning done ==="
echo ""
echo "----- PROVISION SUMMARY -----"
cat "${LOG_DIR}/summary.txt"
echo "-----------------------------"
exit 0
