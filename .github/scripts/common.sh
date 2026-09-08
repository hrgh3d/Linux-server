#!/bin/bash
# ============================================================================
# common.sh — توابع مشترک لایه‌ی ماندگاری (Persistence).
#
# داده‌ها در یک آرشیو تک‌نسخه‌ای (state.tar.gz) بر روی Release با تگ 'state'
# در مخزن اختصاصی PERSIST_REPO ذخیره و بازیابی می‌شوند.
#
# این اسکریپت از state_sync.py برای برقراری ارتباط مطمئن با GitHub API استفاده می‌کند.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export STATE_TAG="${STATE_TAG:-state}"
export PERSIST_REPO="${PERSIST_REPO:-hrgh3d/Linux-server-state}"
export PERSIST_TOKEN="${PERSIST_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}"

log() { echo "[persist $(date -u '+%T')] $*"; }

download_state() {
  local dest="${1:-state.tar.gz}"
  if python3 "$SCRIPT_DIR/state_sync.py" download "$dest"; then
    log "state downloaded successfully -> $dest"
    return 0
  else
    log "no existing state archive found or download failed"
    return 1
  fi
}

upload_state() {
  local src="${1:-state.tar.gz}"
  if [ ! -f "$src" ]; then
    log "ERROR: archive ${src} does not exist"
    return 1
  fi
  if python3 "$SCRIPT_DIR/state_sync.py" upload "$src"; then
    log "state successfully uploaded to $PERSIST_REPO tag '$STATE_TAG'"
    return 0
  else
    log "ERROR: upload failed"
    return 1
  fi
}
