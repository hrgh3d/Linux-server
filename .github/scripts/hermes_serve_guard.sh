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
if ! tailscale funnel status 2>/dev/null | grep -q ':10000'; then
  say "funnel missing — re-establishing"
  timeout 60 tailscale funnel --bg --https=10000 "http://${TSIP}:9122" >>"$LOG" 2>&1
fi

# --- ۴) تأیید واقعی از بیرون، نه فقط «active» -----------------------------
LOCAL=$(curl -s -o /dev/null -w '%{http_code}' -m 8 "http://${TSIP}:9122/api/status" 2>/dev/null)
if [ "$LOCAL" != "200" ]; then
  say "backend not answering locally (got $LOCAL) — restarting"
  systemctl restart hermes-serve
fi
