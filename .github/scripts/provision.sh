#!/bin/bash
# ============================================================================
# provision.sh — نصب خودکار و ایدم‌پوتِ نرم‌افزارهای «کاربر» روی هر Boot (v4.3)
#
# این اسکریپت فقط وقتی نرم‌افزار موجود نباشد آن را نصب می‌کند؛ اگر از State
# بازیابی شده باشد کاری نمی‌کند (سریع). نرم‌افزارهای تحت پوشش:
#   1) 9router            (npm global)
#   2) Hermes Agent       (installer رسمی Nous Research — غیرتعاملی)
#   3) 3x-ui              (installer رسمی mhsanaei)
#
# همه‌ی نصب‌ها با timeout و لاگ جداگانه انجام می‌شوند؛ شکست یک نصب باعث
# توقف Boot نمی‌شود (در چرخه‌ی بعد دوباره تلاش می‌شود).
# ============================================================================
set -uo pipefail
LOG_DIR=/tmp/provision
mkdir -p "$LOG_DIR"

log()  { echo "[provision $(date -u '+%T')] $*"; }
note() { echo "[provision] $*" | tee -a "${LOG_DIR}/summary.txt"; }
: > "${LOG_DIR}/summary.txt"

# بسته به نوع runner فرمان root
SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

ensure_npm() {
  command -v npm >/dev/null 2>&1 && return 0
  command -v nodejs >/dev/null 2>&1 || $SUDO apt-get install -y -qq nodejs npm >/dev/null 2>&1 || true
  command -v npm >/dev/null 2>&1
}

# ---------------------------------------------------------------- 9router
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

# ---------------------------------------------------------------- Hermes
provision_hermes() {
  if [ -x /usr/local/bin/hermes ] && [ -d /usr/local/lib/hermes-agent ]; then
    note "hermes: present (FHS restored) — skip"
    return 0
  fi
  if [ -x /root/.hermes/hermes-agent/hermes ] || [ -d /root/.hermes/hermes-agent/.git ]; then
    note "hermes: present (legacy under /root/.hermes) — skip"
    return 0
  fi
  log "hermes: not found — running official installer (non-interactive)..."
  curl -fsSL --max-time 60 https://hermes-agent.nousresearch.com/install.sh -o /tmp/hermes-install.sh \
    || { note "hermes: download of installer FAILED"; return 1; }
  # غیرتعاملی؛ browser/computer-use نصب نمی‌شوند (سنگین) تا چرخه سریع بماند؛
  # کاربر می‌تواند بعداً با 'hermes setup' آن‌ها را فعال کند.
  HERMES_HOME=/root/.hermes \
  timeout 1500 bash /tmp/hermes-install.sh --non-interactive \
      --skip-browser --skip-computer-use \
      >"${LOG_DIR}/hermes.log" 2>&1
  rc=$?
  if [ $rc -eq 0 ] && [ -x /usr/local/bin/hermes ]; then
    note "hermes: INSTALLED ($(/usr/local/bin/hermes --version 2>/dev/null || echo ok))"
  else
    note "hermes: install did not complete (rc=$rc) — see ${LOG_DIR}/hermes.log"
  fi
}

# ---------------------------------------------------------------- 3x-ui
provision_xui() {
  if [ -x /usr/local/x-ui/x-ui ] && [ -d /etc/x-ui ]; then
    note "3x-ui: present (restored) — ensuring service is running"
    $SUDO systemctl daemon-reload >/dev/null 2>&1 || true
    $SUDO systemctl enable x-ui >/dev/null 2>&1 || true
    $SUDO systemctl start x-ui >/dev/null 2>&1 || \
      { $SUDO sh -c 'nohup /usr/local/x-ui/x-ui run >/var/log/x-ui-gh.log 2>&1 &' && sleep 2; }
    return 0
  fi
  log "3x-ui: not found — running official installer..."
  curl -fsSL --max-time 60 https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o /tmp/xui-install.sh \
    || { note "3x-ui: download of installer FAILED"; return 1; }
  timeout 900 $SUDO env XUI_DB_TYPE=sqlite bash /tmp/xui-install.sh </dev/null >"${LOG_DIR}/xui.log" 2>&1
  rc=$?
  if [ $rc -eq 0 ] && [ -x /usr/local/x-ui/x-ui ]; then
    note "3x-ui: INSTALLED (binary at /usr/local/x-ui/x-ui, db in /etc/x-ui)"
    $SUDO systemctl daemon-reload >/dev/null 2>&1 || true
    $SUDO systemctl enable x-ui >/dev/null 2>&1 || true
    $SUDO systemctl start x-ui >/dev/null 2>&1 || true
  else
    note "3x-ui: install did not complete (rc=$rc) — see ${LOG_DIR}/xui.log"
  fi
}

# ------------------------------------------------------------------ main
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
