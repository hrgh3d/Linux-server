#!/bin/bash
# ============================================================================
# env_vault.sh — گاوصندوق متغیرهای محیطی Hermes و OmniRoute
#
# مشکلی که حل می‌کند
# -------------------
# سه سازوکار مستقل روی این سرور .env را خالی می‌کنند و هیچ‌کدام همهٔ
# کلیدها را برنمی‌گردانند:
#
#   ۱) save.sh عمداً TELEGRAM_BOT_TOKEN و REPORT_BOT_TOKEN را پیش از آرشیو
#      خالی می‌کند (تا در مخزن state نیفتند). اگر ران وسط همان پنجره کشته
#      شود، .env با مقدار خالی روی دیسک می‌ماند.
#   ۲) secrets_inject.sh در بوت فقط همان سه کلید را دوباره تزریق می‌کند.
#      هر کلید دیگری — مثل کلید اتصال به OmniRoute — پوشش ندارد.
#   ۳) نصب‌کنندهٔ هرمس .env را از روی قالب بازمی‌سازد. دیده شد که فایل از
#      ۱۲ کلیدِ پر به قالب ۵۵۲ خطی برگشت و کلید OmniRoute کامل گم شد.
#
# سیاست
# ------
#   • هر کلیدِ *پر* در گاوصندوق نگه داشته می‌شود (/var/lib، که persist است)
#   • کلیدی که گم یا خالی شده از گاوصندوق برمی‌گردد
#   • کلیدی که مقدار متفاوتِ **غیرخالی** دارد دست‌نخورده می‌ماند و فقط
#     گاوصندوق تازه می‌شود — کاربر حق دارد مقدار را عوض کند
#   • در پنجرهٔ blanking خودِ save.sh دخالت نمی‌کنیم (sentinel)، مگر کهنه شود
# ============================================================================
set -uo pipefail
VAULT=/var/lib/hermes-guard/vault
LOG=/var/log/env-vault.log
SENTINEL=/run/hermes-env-blanked
STALE=600          # اگر sentinel بیش از ۱۰ دقیقه مانده باشد، ران مرده است
say() { echo "[$(date -u '+%F %T')] $*" >>"$LOG"; }
mkdir -p "$VAULT" 2>/dev/null; chmod 700 "$VAULT" 2>/dev/null

# پنجرهٔ blanking فعالِ save.sh را محترم بشمار
if [ -f "$SENTINEL" ]; then
  age=$(( $(date +%s) - $(stat -c%Y "$SENTINEL" 2>/dev/null || echo 0) ))
  if [ "$age" -lt "$STALE" ]; then exit 0; fi
  say "sentinel stale (${age}s) — the run that set it is gone, proceeding"
fi

vault_one() {
  local name="$1" env="$2" store="$VAULT/$name"
  [ -n "$env" ] || return 0
  touch "$store" 2>/dev/null; chmod 600 "$store" 2>/dev/null

  # ── ذخیره: هر کلید پر را در گاوصندوق تازه کن
  if [ -s "$env" ]; then
    local tmp; tmp=$(mktemp)
    # فقط KEY=VALUE های با مقدار معنادار (≥۴ کاراکتر، نه placeholder)
    grep -E '^[A-Za-z_][A-Za-z0-9_]*=.{4,}' "$env" 2>/dev/null \
      | grep -vE '=(your-|changeme|xxx|<|\$\{)' > "$tmp" || true
    if [ -s "$tmp" ]; then
      # ادغام: کلیدهای تازه اضافه، کلیدهای موجود به‌روز
      awk -F= '!seen[$1]++' <(cat "$tmp" "$store" 2>/dev/null) > "$store.new" 2>/dev/null \
        && mv "$store.new" "$store" && chmod 600 "$store"
    fi
    rm -f "$tmp"
  fi

  # ── بازگردانی: کلیدی که خالی یا غایب است
  [ -s "$store" ] || return 0
  local restored=0 added=0
  while IFS= read -r line; do
    local k="${line%%=*}"
    [ -n "$k" ] || continue
    if grep -qE "^${k}=.{4,}" "$env" 2>/dev/null; then
      continue                               # مقدار دارد، دست نزن
    elif grep -qE "^${k}=" "$env" 2>/dev/null; then
      # هست ولی خالی → پرش کن
      local esc; esc=$(printf '%s' "$line" | sed 's/[&|\\]/\\&/g')
      sed -i "s|^${k}=.*|${esc}|" "$env" && { restored=$((restored+1)); }
    else
      printf '%s\n' "$line" >> "$env"; added=$((added+1))
    fi
  done < "$store"
  chmod 600 "$env" 2>/dev/null
  if [ "$restored" -gt 0 ] || [ "$added" -gt 0 ]; then
    say "$name: restored=$restored added=$added  (vault has $(wc -l <"$store") keys)"
    echo "$name"
  fi
}

CHANGED=""
CHANGED="$CHANGED $(vault_one hermes    /root/.hermes/.env)"
CHANGED="$CHANGED $(vault_one omniroute /root/.omniroute/.env)"

# همان کلیدها را از env.preblank هم بردار (شبکهٔ ایمنی save.sh)
if [ -s /var/lib/hermes-guard/env.preblank ]; then
  grep -E '^[A-Za-z_][A-Za-z0-9_]*=.{4,}' /var/lib/hermes-guard/env.preblank 2>/dev/null \
    | awk -F= '!seen[$1]++' >> "$VAULT/hermes" 2>/dev/null
  awk -F= '!seen[$1]++' "$VAULT/hermes" > "$VAULT/hermes.n" && mv "$VAULT/hermes.n" "$VAULT/hermes"
  chmod 600 "$VAULT/hermes"
fi

# سرویس‌هایی که به کلیدِ برگشته نیاز دارند را تازه کن
if echo "$CHANGED" | grep -q hermes; then
  say "restarting hermes services after key restore"
  systemctl --user -M root@ restart hermes-gateway.service 2>/dev/null \
    || XDG_RUNTIME_DIR=/run/user/0 systemctl --user restart hermes-gateway.service 2>/dev/null
  systemctl restart hermes-serve 2>/dev/null
fi
if echo "$CHANGED" | grep -q omniroute; then
  say "restarting omniroute after key restore"
  systemctl restart omniroute 2>/dev/null
fi
