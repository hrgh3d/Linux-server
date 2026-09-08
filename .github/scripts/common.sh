#!/bin/bash
# ============================================================================
# توابع مشترک لایه‌ی ماندگاری (Persistence).
#
# مدل ذخیره‌سازی:
#   state.tar.gz روی یک GitHub Release چرخشی (tag = $STATE_TAG) نگهداری می‌شود،
#   نه داخل خود git. به این ترتیب فایل‌های حجیم، تاریخچهٔ مخزن را باد نمی‌کنند
#   و با هر reset فقط آخرین نسخه بازگردانی می‌شود.
#
# متغیرهای موردنیاز (از workflow تزریق می‌شوند):
#   GH_TOKEN، GH_REPO (یا GITHUB_REPOSITORY)، STATE_TAG
# ============================================================================
set -euo pipefail

STATE_TAG="${STATE_TAG:-state}"
GH_REPO="${GH_REPO:-${GITHUB_REPOSITORY:-}}"

log() { echo "[persist] $*"; }

# ساخت Release اگر هنوز وجود ندارد
ensure_release() {
  if gh release view "$STATE_TAG" --repo "$GH_REPO" >/dev/null 2>&1; then
    return 0
  fi
  log "creating release tag '${STATE_TAG}'"
  gh release create "$STATE_TAG" --repo "$GH_REPO" \
    --title "Persistent state (rolling)" \
    --notes "Rolling state archive for Linux-server — updated automatically by the workflow." \
    >/dev/null 2>&1 || log "WARNING: could not create release"
}

# دانلود آخرین state (خروجی: مسیر فایل). در نبود state خروجی غیرصفر برمی‌گرداند.
download_state() {
  local dest="${1:-state.tar.gz}"
  if gh release download "$STATE_TAG" --repo "$GH_REPO" -p state.tar.gz -O "$dest" >/dev/null 2>&1; then
    log "state.tar.gz downloaded from release '${STATE_TAG}'"
    return 0
  fi
  log "no state archive on release yet"
  return 1
}

# آپلود state فعلی (نسخهٔ قبلی بازنویسی می‌شود)
upload_state() {
  local src="${1:-state.tar.gz}"
  [ -f "$src" ] || { log "ERROR: ${src} not found"; return 1; }
  ensure_release
  gh release upload "$STATE_TAG" "$src" --repo "$GH_REPO" --clobber >/dev/null 2>&1 \
    && log "state uploaded to release '${STATE_TAG}'" \
    || log "WARNING: upload failed"
}
