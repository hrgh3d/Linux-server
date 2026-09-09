#!/usr/bin/env bash
# start-services.sh — استارت سرویس‌های ماندگار بعد از restore (v6.3)
# مشکل: یونیت‌های Hermes در state ذخیره می‌شوند ولی روی رانر تازه هیچ‌چیز
# آن‌ها را استارت نمی‌کند (سم‌لینک‌های wants فقط موقع بوت سیستم اثر دارند
# و رانر قبل از restore بالا آمده). این اسکریپت همه را بالا می‌آورد.
# غیرکشنده: خرابی یک سرویس اپ نباید بوت سرور را fail کند (exit همیشه 0).
set -uo pipefail

fail=0

start_system() { # start_system <unit>
  local u="$1"
  if [ ! -f "/etc/systemd/system/$u" ]; then
    echo "[services] $u: unit file absent — skip"
    return 0
  fi
  sudo systemctl daemon-reload >/dev/null 2>&1 || true
  sudo systemctl enable "$u" >/dev/null 2>&1 || true
  if sudo systemctl start "$u" >/dev/null 2>&1; then
    echo "[services] $u: started"
  else
    echo "[services] WARNING: $u failed to start (non-fatal, boot continues)"
    sudo systemctl status "$u" --no-pager -l 2>/dev/null | tail -4 || true
    fail=1
  fi
}

# --- Hermes: سرویس‌های سیستمی (داشبورد + تانل کلادفلر) ---
start_system hermes-dashboard.service
start_system hermes-tunnel.service

# --- Hermes gateway: یونیت user روت = اتصال تلگرام ---
if [ -f /root/.config/systemd/user/hermes-gateway.service ]; then
  sudo loginctl enable-linger root >/dev/null 2>&1 || true
  sudo systemctl start 'user@0.service' >/dev/null 2>&1 || true
  sleep 2
  export XDG_RUNTIME_DIR=/run/user/0
  if [ -d "$XDG_RUNTIME_DIR" ]; then
    sudo -u root XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user daemon-reload >/dev/null 2>&1 || true
    sudo -u root XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user enable hermes-gateway.service >/dev/null 2>&1 || true
    if sudo -u root XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user start hermes-gateway.service >/dev/null 2>&1; then
      echo "[services] hermes-gateway.service (user): started"
    else
      echo "[services] WARNING: hermes-gateway failed to start (non-fatal, boot continues)"
      fail=1
    fi
  else
    echo "[services] WARNING: /run/user/0 missing — gateway skipped (non-fatal)"
    fail=1
  fi
else
  echo "[services] hermes-gateway.service: unit file absent — skip"
fi

# --- راستی‌آزمایی ---
echo "[services] status:"
sudo systemctl is-active hermes-dashboard.service hermes-tunnel.service 2>/dev/null || true
if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ':9119'; then
  echo "[services] dashboard port 9119: LISTENING"
else
  echo "[services] dashboard port 9119: not listening (yet)"
fi
if [ "$fail" -ne 0 ]; then
  echo "[services] DONE with warnings (boot continues)"
else
  echo "[services] DONE — all requested services started"
fi
exit 0
