#!/bin/bash
# ============================================================================
# provision.sh — v4.5.2 pure Mode 2 + cloudflared + hermes recovery
#   - حالت ۲: اگر کاربر قبلاً Hermes داشته (/root/.hermes exists) ولی باینری پاک شده (به خاطر prune قدیمی)، دوباره نصب کن
#   - اگر کاربر کل /root/.hermes را پاک کرده، نصب نکن (کاربر نمی‌خواهد)
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
  if [ -x /usr/local/bin/9router ]; then
    note "9router: present — kept (Mode 2)"
  else
    # اگر قبلاً نصب بوده (دیتا موجود) ولی باینری نیست، دوباره نصب کن (recovery از prune قدیمی)
    if [ -d /root/.9router ] || [ -d /home/Hamid/.9router ]; then
      log "9router: data exists but binary missing — reinstalling (recovery)..."
      if ensure_npm && timeout 300 $SUDO env PATH="$PATH" npm install -g 9router >"${LOG_DIR}/9router.log" 2>&1; then
        note "9router: REINSTALLED (recovery)"
      else
        note "9router: recovery FAILED"
      fi
    else
      note "9router: not present — NOT reinstalling (Mode 2)"
    fi
  fi
}

provision_hermes() {
  if [ -x /usr/local/bin/hermes ] && [ -d /usr/local/lib/hermes-agent ]; then
    note "hermes: present — kept (Mode 2)"
    return 0
  fi
  if [ -x /root/.hermes/hermes-agent/hermes ] || [ -d /root/.hermes/hermes-agent/.git ]; then
    note "hermes: present legacy — kept (Mode 2)"
    return 0
  fi
  # اگر /root/.hermes وجود دارد یعنی کاربر قبلاً Hermes داشته، ولی باینری به خاطر prune قدیمی پاک شده -> recovery
  if [ -d /root/.hermes ]; then
    log "hermes: data /root/.hermes exists but binary missing — reinstalling (recovery from old prune)..."
    curl -fsSL --max-time 60 https://hermes-agent.nousresearch.com/install.sh -o /tmp/hermes-install.sh || { note "hermes: download FAILED"; return 1; }
    timeout 1500 $SUDO env HERMES_HOME=/root/.hermes bash /tmp/hermes-install.sh --non-interactive --skip-browser --skip-computer-use >"${LOG_DIR}/hermes.log" 2>&1
    rc=$?
    if [ $rc -eq 0 ] && { [ -x /usr/local/bin/hermes ] || [ -x /root/.hermes/hermes-agent/hermes ]; }; then
      note "hermes: REINSTALLED (recovery, binary restored)"
    else
      note "hermes: recovery FAILED (rc=$rc)"
      tail -20 "${LOG_DIR}/hermes.log" 2>/dev/null | tee -a "${LOG_DIR}/summary.txt"
    fi
  else
    note "hermes: not present and no data — NOT reinstalling (Mode 2, user never installed)"
  fi
}

provision_xui() {
  note "3x-ui: disabled by user — skip (Mode 2)"
}

provision_cloudflared() {
  local found=""
  for p in /usr/local/bin/cloudflared /usr/bin/cloudflared /root/.hermes/bin/cloudflared /root/cloudflared /opt/cloudflared; do
    if [ -x "$p" ]; then found="$p"; break; fi
  done
  if [ -n "$found" ]; then
    note "cloudflared: found at $found — ensured in /usr/local/bin"
    if [ "$found" != "/usr/local/bin/cloudflared" ]; then
      $SUDO cp -f "$found" /usr/local/bin/cloudflared 2>/dev/null || true
      $SUDO chmod +x /usr/local/bin/cloudflared 2>/dev/null || true
    fi
  else
    if [ -d /root/.hermes ]; then
      log "cloudflared: not found but hermes data exists — downloading (recovery)..."
      if curl -fsSL --max-time 60 https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /tmp/cloudflared; then
        $SUDO mv /tmp/cloudflared /usr/local/bin/cloudflared
        $SUDO chmod +x /usr/local/bin/cloudflared
        note "cloudflared: INSTALLED (recovery)"
      else
        note "cloudflared: download failed"
      fi
    else
      note "cloudflared: not found — skip"
    fi
  fi
}

log "=== provisioning start (Mode 2 + recovery) ==="
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
