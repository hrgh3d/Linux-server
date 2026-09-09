#!/bin/bash
# ============================================================================
# provision.sh — v4.5.1 pure Mode 2 + cloudflared persistence
#   - حالت ۲ خالص: هیچ برنامه‌ای به صورت ثابت نصب نمی‌شود
#   - cloudflared برای تانل‌های موقت باید بین ران‌ها بماند
# ============================================================================
set -uo pipefail
LOG_DIR=/tmp/provision
mkdir -p "$LOG_DIR"
log()  { echo "[provision $(date -u '+%T')] $*"; }
note() { echo "[provision] $*" | tee -a "${LOG_DIR}/summary.txt"; }
: > "${LOG_DIR}/summary.txt"
SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

provision_9router() {
  if [ -x /usr/local/bin/9router ]; then
    note "9router: present — kept (Mode 2)"
  else
    note "9router: not present — NOT reinstalling (Mode 2)"
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
  if [ -d /etc/x-ui ] || [ -d /usr/local/x-ui ]; then
    note "3x-ui: found but user disabled — will not be reinstalled (Mode 2)"
  else
    note "3x-ui: disabled by user — skip (Mode 2)"
  fi
}

provision_cloudflared() {
  # cloudflared برای تانل موقت داشبوردها - باید بین ران‌ها بماند
  # ممکن است در جاهای مختلف نصب شده باشد، آن را به /usr/local/bin منتقل می‌کنیم که persist می‌شود
  local found=""
  for p in /usr/local/bin/cloudflared /usr/bin/cloudflared /root/.hermes/bin/cloudflared /root/cloudflared /opt/cloudflared; do
    if [ -x "$p" ]; then
      found="$p"
      break
    fi
  done
  if [ -n "$found" ]; then
    note "cloudflared: found at $found — ensuring in /usr/local/bin (persisted)"
    if [ "$found" != "/usr/local/bin/cloudflared" ]; then
      $SUDO cp -f "$found" /usr/local/bin/cloudflared 2>/dev/null || true
      $SUDO chmod +x /usr/local/bin/cloudflared 2>/dev/null || true
    fi
  else
    # اگر اصلاً وجود ندارد، سعی کن نصبش کنی (برای اینکه تانل کار کند)
    # این فقط یک بار اتفاق می‌افتد، بعدش به خاطر persist دیگر پاک نمی‌شود
    if command -v curl >/dev/null 2>&1; then
      log "cloudflared: not found — downloading binary (will be persisted)..."
      # دانلود آخرین نسخه برای linux amd64
      if curl -fsSL --max-time 60 https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /tmp/cloudflared; then
        $SUDO mv /tmp/cloudflared /usr/local/bin/cloudflared
        $SUDO chmod +x /usr/local/bin/cloudflared
        note "cloudflared: INSTALLED to /usr/local/bin/cloudflared (will persist)"
      else
        note "cloudflared: download failed — tunnel may need reinstall"
      fi
    else
      note "cloudflared: not found — skip"
    fi
  fi
}

log "=== provisioning start (Mode 2 + cloudflared) ==="
provision_9router
provision_hermes
provision_xui
provision_cloudflared
log "=== provisioning done ==="
echo ""
echo "----- PROVISION SUMMARY (Mode 2) -----"
cat "${LOG_DIR}/summary.txt"
echo "-----------------------------"
exit 0
