#!/bin/bash
# ============================================================================
# secrets_inject.sh (v6.10) — تزریق secretهای «خارج‌شده از آرشیو» به فایل‌های
# روی دیسک، بعد از Restore و قبل از استارت سرویس‌ها.
#
# معماری: secretها هرگز وارد آرشیو state نمی‌شوند (save.sh قبل از tar خط
# متناظر را خالی می‌کند) و در هر بوت از GitHub Secrets تزریق می‌شوند:
#   * TELEGRAM_BOT_TOKEN  ->  /root/.hermes/.env  (خط واحد، idempotent)
#
# Non-fatal: اگر secret تنظیم نباشد، فقط WARN می‌زند و بوت ادامه می‌یابد.
# ============================================================================
set -uo pipefail

ENV_FILE=/root/.hermes/.env
log() { echo "[secrets $(date -u '+%T')] $*"; }

# جایگزین/افزودن یک خط KEY=VALUE در فایل env (بدون تغییر بقیه خطوط)
inject_env_line() {
  local key="$1" value="$2" file="$3"
  if [ -z "$value" ]; then
    log "WARN: secret ${key} not set — skipping injection"
    return 0
  fi
  local line="${key}=${value}"
  if [ -f "$file" ]; then
    if grep -q "^${key}=" "$file" 2>/dev/null; then
      local tmp; tmp=$(mktemp)
      awk -v k="$key" -v line="$line" \
        'BEGIN{done=0}
         { if ($0 ~ "^" k "=") { if (!done) { print line; done=1 } next } print }
         END{ if (!done) print line }' \
        "$file" > "$tmp" && cat "$tmp" > "$file"
      rm -f "$tmp"
    else
      echo "$line" >> "$file"
    fi
    log "injected ${key} into ${file}"
  else
    mkdir -p "$(dirname "$file")"
    echo "$line" > "$file"
    log "created ${file} with ${key}"
  fi
  chmod 600 "$file" 2>/dev/null || true
}

inject_env_line "TELEGRAM_BOT_TOKEN" "${TELEGRAM_BOT_TOKEN:-}" "$ENV_FILE"

log "secrets injection done."
