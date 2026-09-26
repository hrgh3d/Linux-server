#!/bin/bash
# ============================================================================
# omniroute_guard.sh — نگهبان OmniRoute
#
# دو چیز را نگه می‌دارد:
#   ۱) سرویس واقعاً در حال اجرا و پاسخ‌گو باشد (نه فقط systemd active)
#   ۲) **کلیدهای رمز عوض نشده باشند.** OmniRoute اعتبارنامهٔ ارائه‌دهنده‌ها
#      را با AES رمز می‌کند و کلیدش از JWT_SECRET/API_KEY_SECRET می‌آید.
#      اگر اینها عوض شوند، همهٔ کلیدهای کاربر بی‌سروصدا از کار می‌افتند —
#      سرویس بالا می‌آید، داشبورد باز می‌شود، ولی هیچ ارائه‌دهنده‌ای جواب
#      نمی‌دهد. این بدترین نوع خرابی است چون شبیه خرابی نیست.
# ============================================================================
set -uo pipefail
LOG=/var/log/omniroute-guard.log
ENV=/root/.omniroute/.env
BAK=/root/.omniroute-secrets
DB=/root/.omniroute/storage.sqlite
say() { echo "[$(date -u '+%F %T')] $*" >>"$LOG"; }

command -v omniroute >/dev/null 2>&1 || { say "omniroute not installed"; exit 0; }

# --- ۱) نگهبانی کلیدها ------------------------------------------------------
if [ -s "$ENV" ]; then
  if [ ! -s "$BAK" ]; then
    cp "$ENV" "$BAK"; chmod 600 "$BAK"; say "secret backup created"
  elif ! cmp -s "$ENV" "$BAK"; then
    # فقط وقتی هشدار بده که *کلیدها* فرق کرده‌اند، نه هر تغییر بی‌خطری
    for k in JWT_SECRET API_KEY_SECRET; do
      A=$(grep "^$k=" "$ENV" 2>/dev/null | cut -d= -f2-)
      B=$(grep "^$k=" "$BAK" 2>/dev/null | cut -d= -f2-)
      if [ -n "$B" ] && [ "$A" != "$B" ]; then
        say "✖ $k CHANGED — restoring from backup (new keys would orphan every stored credential)"
        cp "$BAK" "$ENV"; chmod 600 "$ENV"
        systemctl restart omniroute
        break
      fi
    done
    # کلیدها یکی‌اند ⇒ تغییرِ بی‌خطر بوده، پشتیبان را تازه کن
    cmp -s "$ENV" "$BAK" || { cp "$ENV" "$BAK"; chmod 600 "$BAK"; }
  fi
elif [ -s "$DB" ] && [ -s "$BAK" ]; then
  say "✖ .env vanished while DB exists — restoring from secret backup"
  cp "$BAK" "$ENV"; chmod 600 "$ENV"; systemctl restart omniroute
fi

# --- ۲) سرویس -------------------------------------------------------------
if [ ! -f /etc/systemd/system/omniroute.service ]; then
  say "unit missing — boot script will recreate it"
fi
systemctl is-active --quiet omniroute || { say "not active — starting"; systemctl start omniroute; sleep 15; }

# --- ۳) تأیید واقعی، نه اتکا به active -------------------------------------
C=$(curl -s -o /dev/null -w '%{http_code}' -m 8 http://127.0.0.1:20130/api/status 2>/dev/null)
case "$C" in
  200|401|307|302) : ;;   # زنده (۴۰۱/۳۰۷ یعنی دروازهٔ ورود، سالم است)
  *) say "not answering (got '$C') — restarting"; systemctl restart omniroute ;;
esac

# --- ۴) مسیر Serve روی tailnet ---------------------------------------------
if ! tailscale serve status 2>/dev/null | grep -q '127.0.0.1:20130'; then
  say "serve 9447 missing — re-establishing"
  timeout 60 tailscale serve --bg --https=9447 http://127.0.0.1:20130 >>"$LOG" 2>&1
fi

# --- ۵) پشتیبان روزانه از دیتابیس ------------------------------------------
SNAP=/root/backups/omniroute-daily.sqlite
if [ ! -s "$SNAP" ] || [ $(( $(date +%s) - $(stat -c%Y "$SNAP" 2>/dev/null || echo 0) )) -gt 82800 ]; then
  mkdir -p /root/backups
  sqlite3 "$DB" "VACUUM INTO '${SNAP}.tmp'" 2>/dev/null && mv "${SNAP}.tmp" "$SNAP" \
    && say "daily db snapshot refreshed ($(du -h "$SNAP"|cut -f1))"
fi
