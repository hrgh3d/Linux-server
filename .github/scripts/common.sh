#!/bin/bash
# ============================================================================
# common.sh — توابع مشترک لایه‌ی ماندگاری (Persistence) — نسخه‌ی v4.
#
# داده‌ها در قالب یک اسنپ‌شات چرخشی (state-*.tar.gz) روی Release با تگ 'state'
# در مخزن اختصاصی PERSIST_REPO نگهداری می‌شوند. اسکریپت state_sync.py:
#   - آپلود با نام یکتا + حذف نسخه‌های قدیمی => همیشه دقیقاً یک state نگهداری می‌شود.
#   - اگر محتوا نسبت به آخرین state تغییر نکرده باشد، آپلودی رخ نمی‌دهد
#     (بدون تولید بکاپ اضافی حتی با Run مجدد یا Cancel پشت سر هم).
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
    log "state downloaded successfully -> $dest ($(du -h "$dest" 2>/dev/null | cut -f1))"
    return 0
  else
    log "no existing state archive found or download failed"
    return 1
  fi
}

# 0 = موفق (ذخیره شد یا به‌دلیل عدم تغییر رد شد)، 1 = خطا
upload_state() {
  local src="${1:-state.tar.gz}"
  if [ ! -f "$src" ]; then
    log "ERROR: archive ${src} does not exist"
    return 1
  fi
  if python3 "$SCRIPT_DIR/state_sync.py" upload "$src"; then
    log "state synced OK -> $PERSIST_REPO tag '$STATE_TAG'"
    return 0
  else
    log "ERROR: state upload failed"
    return 1
  fi
}
