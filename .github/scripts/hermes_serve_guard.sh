#!/bin/bash
# ============================================================================
# hermes_serve_guard.sh — نگهبان backend اپ دسکتاپ هرمس
#
# چرا لازم شد: دو بار پشت سر هم بعد از تعویض رانر، اتصال Hermes Desktop
# قطع شد. دو علت مستقل داشت و هر دو خاموش بودند:
#
#   ۱) یونیت از اسنپ‌شات برمی‌گشت و enabled بود، ولی **استارت نمی‌شد**.
#      یونیتی که بعد از بوت روی دیسک نوشته شود، با daemon-reload خودکار
#      اجرا نمی‌شود — systemd فقط در بوت به enabled نگاه می‌کند.
#
#   ۲) خودِ هرمس هنگام مهاجرت پیکربندی، config.yaml را بازنویسی می‌کند و
#      `dashboard.public_url` را می‌انداخت. بدون آن نگهبان Host هر
#      درخواست Funnel را با ۴۰۰ رد می‌کند («Invalid Host header») در حالی
#      که سرویس ظاهراً سالم است — خرابی خاموش.
#
# پس این نگهبان هر دو را هر چند دقیقه بررسی می‌کند. ویرایش دستی YAML
# نمی‌کنیم؛ `hermes config set` استفاده می‌شود که بازنویسی را تحمل می‌کند.
# ============================================================================
set -uo pipefail
export HERMES_HOME=/root/.hermes
PATH=/usr/local/lib/hermes-agent/venv/bin:/usr/local/bin:/root/.local/bin:$PATH
LOG=/var/log/hermes-serve-guard.log
PUBLIC="https://linux-server-vps.tail3641f4.ts.net:10000"
say() { echo "[$(date -u '+%F %T')] $*" >>"$LOG"; }

TSIP=$(tailscale ip -4 2>/dev/null | head -1)
[ -n "$TSIP" ] || { say "no tailscale IP yet"; exit 0; }
[ -x /usr/local/lib/hermes-agent/venv/bin/python ] || { say "hermes venv missing"; exit 0; }

# --- ۱) public_url باید باشد، وگرنه Funnel با ۴۰۰ رد می‌شود -----------------
CUR=$(timeout 30 hermes config get dashboard.public_url </dev/null 2>/dev/null | tail -1)
if [ "$CUR" != "$PUBLIC" ]; then
  say "public_url was '$CUR' — restoring"
  timeout 45 hermes config set dashboard.public_url "$PUBLIC" </dev/null >>"$LOG" 2>&1
  NEEDS_RESTART=1
fi

# --- ۱.۵) کلید امضای کوکی نشست ---------------------------------------------
# بدون HERMES_DASHBOARD_BASIC_AUTH_SECRET، هرمس هر بار کلید تصادفی می‌سازد و
# همهٔ کوکی‌های قبلی باطل می‌شوند ⇒ اپ دسکتاپ 401 با reason=no_cookie می‌گیرد
# و مدام Sign in می‌خواهد. نصب‌کننده این کلید را از .env پاک کرده بود.
if ! grep -qE '^HERMES_DASHBOARD_BASIC_AUTH_SECRET=.{16,}' /root/.hermes/.env 2>/dev/null; then
  _sec=$(openssl rand -base64 48 2>/dev/null | tr -d '\n')
  sed -i '/^HERMES_DASHBOARD_BASIC_AUTH_SECRET=/d' /root/.hermes/.env 2>/dev/null
  printf 'HERMES_DASHBOARD_BASIC_AUTH_SECRET=%s\n' "$_sec" >> /root/.hermes/.env
  chmod 600 /root/.hermes/.env
  say "cookie signing secret was missing — generated a stable one (sessions will now survive restarts)"
  NEEDS_RESTART=1
fi

# --- ۲) سرویس باید واقعاً در حال اجرا باشد، نه فقط enabled -----------------
if [ ! -f /etc/systemd/system/hermes-serve.service ]; then
  say "unit missing — recreating"
  cat > /etc/systemd/system/hermes-serve.service <<EOF
[Unit]
Description=Hermes backend for Hermes Desktop (remote gateway)
After=network-online.target tailscaled.service
Wants=network-online.target
[Service]
Type=simple
User=root
WorkingDirectory=/root/.hermes
EnvironmentFile=/root/.hermes/.env
Environment="HERMES_HOME=/root/.hermes"
Environment="PATH=/usr/local/lib/hermes-agent/venv/bin:/usr/local/bin:/root/.local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="VIRTUAL_ENV=/usr/local/lib/hermes-agent/venv"
ExecStart=/usr/local/lib/hermes-agent/venv/bin/python -m hermes_cli.main serve --host ${TSIP} --port 9122 --skip-build
Restart=always
RestartSec=8
KillMode=mixed
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable hermes-serve >/dev/null 2>&1
  NEEDS_RESTART=1
fi

# آدرس bind عوض شده؟ (تعویض رانر می‌تواند IP را جابه‌جا کند)
grep -q -- "--host ${TSIP} " /etc/systemd/system/hermes-serve.service || {
  say "bind address changed → ${TSIP}"
  sed -i "s|--host [0-9.]*|--host ${TSIP}|" /etc/systemd/system/hermes-serve.service
  systemctl daemon-reload; NEEDS_RESTART=1
}

if [ "${NEEDS_RESTART:-0}" = "1" ] || ! systemctl is-active --quiet hermes-serve; then
  say "starting hermes-serve (active=$(systemctl is-active hermes-serve))"
  systemctl restart hermes-serve
  sleep 20
fi

# --- ۳) Funnel ------------------------------------------------------------
# ⚠️ فقط وقتی دوباره بساز که واقعاً پاسخ ندهد.
# قبلاً بر اساس grep روی خروجی `funnel status` تصمیم می‌گرفت و مثبتِ کاذب
# می‌داد: هر ۴ دقیقه funnel را از نو می‌ساخت و اتصال دائمیِ اپ دسکتاپ قطع
# می‌شد — یعنی خودِ نگهبان عامل Sign in مکرر بود.
# منبع معتبر و محلی: AllowFunnel در خروجی json، نه متن انسانی.
_fon=$(tailscale serve status --json 2>/dev/null \
       | python3 -c "import json,sys
try: print('yes' if any(':10000' in k and v for k,v in (json.load(sys.stdin).get('AllowFunnel') or {}).items()) else 'no')
except Exception: print('unknown')" 2>/dev/null)
_fc=$(curl -s -o /dev/null -w '%{http_code}' -m 12 \
      "https://linux-server-vps.tail3641f4.ts.net:10000/api/status" 2>/dev/null)
case "$_fc" in
  200|401|302|307) : ;;                      # زنده است، دست نزن
  *)
    if [ "$_fon" = "yes" ]; then
      say "funnel registered but endpoint returned '$_fc' — backend issue, not re-creating"
    else
      say "funnel really down (AllowFunnel=$_fon http=$_fc) — re-establishing"
      timeout 60 tailscale funnel --bg --https=10000 "http://${TSIP}:9122" >>"$LOG" 2>&1
    fi
    ;;
esac

# --- ۴) تأیید واقعی از بیرون، نه فقط «active» -----------------------------
LOCAL=$(curl -s -o /dev/null -w '%{http_code}' -m 8 "http://${TSIP}:9122/api/status" 2>/dev/null)
if [ "$LOCAL" != "200" ]; then
  say "backend not answering locally (got $LOCAL) — restarting"
  systemctl restart hermes-serve
fi

# --- ۵) هم‌ترازی نسخه با اپ دسکتاپ ----------------------------------------
# کد نصب‌شده از main است و از آخرین تگ ریلیز **جلوتر**، ولی فایل نسخه روی
# main فقط موقع ریلیز به‌روز می‌شود و روی 0.21.3 می‌ماند. اپ دسکتاپ همین
# رشته را مقایسه می‌کند و «Backend out of date» می‌دهد — هشداری که واقعیت
# ندارد. هر نصب دوباره این را برمی‌گرداند، پس نگهبان دوباره اعمالش می‌کند.
REL_V=0.21.5
REL_D=2026.9.24
for f in /usr/local/lib/hermes-agent/pyproject.toml \
         /usr/local/lib/hermes-agent/hermes_cli/__init__.py; do
  [ -f "$f" ] || continue
  if grep -qE '^(version|__version__) = "0\.21\.[0-4]"' "$f"; then
    sed -i -E "s/^version = \"0\.21\.[0-4]\"/version = \"${REL_V}\"/;
               s/^__version__ = \"0\.21\.[0-4]\"/__version__ = \"${REL_V}\"/;
               s/^__release_date__ = \"2026\.9\.(7|11|14|21)\"/__release_date__ = \"${REL_D}\"/" "$f"
    say "version string realigned to ${REL_V} in $(basename "$f")"
    NEEDS_RESTART=1
  fi
done
[ "${NEEDS_RESTART:-0}" = "1" ] && systemctl restart hermes-serve 2>/dev/null

# --- ۶) یونیت user گیت‌وی باید enabled بماند -------------------------------
# تعویض رانر آن را به disabled برمی‌گرداند و بوت بعدی خودکار بالا نمی‌آید.
export XDG_RUNTIME_DIR=/run/user/0
if [ "$(systemctl --user is-enabled hermes-gateway.service 2>/dev/null)" != "enabled" ]; then
  systemctl --user enable hermes-gateway.service >/dev/null 2>&1 && say "re-enabled hermes-gateway user unit"
fi
systemctl --user is-active --quiet hermes-gateway.service || {
  say "gateway not running — starting"; systemctl --user start hermes-gateway.service 2>/dev/null; }
