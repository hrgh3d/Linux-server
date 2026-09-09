#!/bin/bash
# ============================================================================
# provision.sh — v4.5 pure Mode 2 (user request)
#   - دیگر هیچ برنامه‌ای به صورت ثابت نصب نمی‌شود
#   - فقط اگر برنامه‌ای از طریق apt/npm/pip نصب شده باشد، از طریق installed.json برمی‌گردد (Mode 2)
#   - برای اپ‌های کاستوم (مثل 9router/Hermes) که قبلاً در لیست ثابت بودند،
#     اگر کاربر حذفشان کند دیگر نصب نمی‌شوند (Mode 2)
#   - 3x-ui به درخواست کاربر کاملاً غیرفعال است
# ============================================================================
set -uo pipefail
LOG_DIR=/tmp/provision
mkdir -p "$LOG_DIR"
log()  { echo "[provision $(date -u '+%T')] $*"; }
note() { echo "[provision] $*" | tee -a "${LOG_DIR}/summary.txt"; }
: > "${LOG_DIR}/summary.txt"
SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

# دیگر نصب خودکار نداریم - فقط گزارش وضعیت فعلی
provision_9router() {
  if [ -x /usr/local/bin/9router ]; then
    note "9router: present — kept (Mode 2)"
  else
    note "9router: not present — NOT reinstalling (Mode 2, user removed or never installed)"
  fi
}

provision_hermes() {
  if [ -x /usr/local/bin/hermes ] || [ -x /root/.hermes/hermes-agent/hermes ]; then
    note "hermes: present — kept (Mode 2)"
  else
    note "hermes: not present — NOT reinstalling (Mode 2)"
  fi
}

provision_xui() {
  # کاربر 3x-ui را نمی‌خواهد - هیچ کاری نمی‌کنیم، حتی پاکسازی تکراری هم نه
  # چون state الان تمیز است، دیگر برنمی‌گردد
  if [ -d /etc/x-ui ] || [ -d /usr/local/x-ui ]; then
    note "3x-ui: found but user disabled — will be removed by payload clean (no auto-reinstall)"
  else
    note "3x-ui: disabled by user — skip (Mode 2)"
  fi
}

log "=== provisioning start (Mode 2 - no fixed list) ==="
provision_9router
provision_hermes
provision_xui
log "=== provisioning done ==="
echo ""
echo "----- PROVISION SUMMARY (Mode 2) -----"
cat "${LOG_DIR}/summary.txt"
echo "-----------------------------"
exit 0
