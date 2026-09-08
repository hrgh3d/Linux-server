#!/bin/bash
# ============================================================================
# توابع مشترک لایه‌ی ماندگاری (Persistence).
#
# محل ذخیره‌سازی:
#   state.tar.gz روی یک GitHub Release چرخشی (tag = $STATE_TAG) در یک مخزن
#   جداگانه‌ی اختصاصی (PERSIST_REPO) نگهداری می‌شود — نه در مخزن کد و نه در git.
#   بنابراین:
#     • فایل‌های حجیم تاریخچهٔ git را باد نمی‌کنند
#     • با حذف workflow یا حتی حذف مخزن اصلی، داده‌ها سالم می‌مانند
#     • همیشه فقط یک نسخهٔ rolling وجود دارد (بکاپ‌های تکراری انباشته نمی‌شوند)
#
# متغیرهای موردنیاز (از workflow تزریق می‌شوند):
#   PERSIST_REPO    → مخزن state (مثلاً hrgh3d/Linux-server-state)
#   PERSIST_TOKEN   → توکنی که به مخزن state دسترسی نوشتن دارد
#   STATE_TAG       → نام تگ Release (پیش‌فرض state)
# ============================================================================
set -euo pipefail

STATE_TAG="${STATE_TAG:-state}"
STATE_REPO="${PERSIST_REPO:-${GITHUB_REPOSITORY:-}}"

# برای کار با مخزن state از توکن اختصاصی استفاده می‌کنیم (GITHUB_TOKEN فقط به
# مخزنِ جاری دسترسی دارد و نمی‌تواند در مخزن دیگر چیزی بنویسد)
export GH_TOKEN="${PERSIST_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}"
export GH_REPO="$STATE_REPO"

log() { echo "[persist] $*"; }

# ساخت Release اگر هنوز وجود ندارد
ensure_release() {
  if gh release view "$STATE_TAG" --repo "$STATE_REPO" >/dev/null 2>&1; then
    return 0
  fi
  log "creating release tag '${STATE_TAG}' on ${STATE_REPO}"
  gh release create "$STATE_TAG" --repo "$STATE_REPO" \
    --title "Persistent state (rolling)" \
    --notes "Rolling state archive for Linux-server — updated automatically by the workflow." \
    >/dev/null 2>&1 || log "WARNING: could not create release"
}

# دانلود آخرین state (خروجی: مسیر فایل). در نبود state خروجی غیرصفر برمی‌گرداند.
download_state() {
  local dest="${1:-state.tar.gz}"
  if gh release download "$STATE_TAG" --repo "$STATE_REPO" -p state.tar.gz -O "$dest" >/dev/null 2>&1; then
    log "state.tar.gz downloaded from release '${STATE_TAG}' (${STATE_REPO})"
    return 0
  fi
  log "no state archive on release yet"
  return 1
}

# آپلود state فعلی (نسخهٔ قبلی بازنویسی می‌شود — همیشه فقط یک بکاپ rolling)
upload_state() {
  local src="${1:-state.tar.gz}"
  [ -f "$src" ] || { log "ERROR: ${src} not found"; return 1; }
  ensure_release
  gh release upload "$STATE_TAG" "$src" --repo "$STATE_REPO" --clobber >/dev/null 2>&1 \
    && log "state uploaded to release '${STATE_TAG}' (${STATE_REPO})" \
    || log "WARNING: upload failed"
}
