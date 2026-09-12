#!/usr/bin/env bash
# start-services.sh — استارت سرویس‌های ماندگار بعد از restore (v6.4 - gateway fix)
# v6.4: رفع مشکل hermes-gateway که بین ران‌ها fail می‌شد
#   - صبر بیشتر برای user@0.service و /run/user/0
#   - fallback اجرای مستقیم gateway اگر user service fail شد
#   - لاگ دقیق‌تر برای دیباگ
set -uo pipefail

fail=0

start_system() {
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
    sudo systemctl status "$u" --no-pager -l 2>/dev/null | tail -10 || true
    fail=1
  fi
}

# --- Hermes: سرویس‌های سیستمی ---
start_system hermes-dashboard.service
start_system hermes-tunnel.service

# --- Hermes gateway: یونیت user روت ---
# v6.11: اگر یونیت گم شده باشد (خرابی state)، همین‌جا بازسازی‌اش کن —
# بوت‌های بعدی از راه استاندارد (همین یونیت) بالا می‌آیند.
GW_UNIT=/root/.config/systemd/user/hermes-gateway.service
# v6.11b: دایرکتوری لاگ هر بوت تضمین شود — بدون آن خود gateway موقع نوشتن
# لاگ کرش می‌کند (دقیقاً همان‌طور که در بازسازی دستی دیدیم).
sudo mkdir -p /root/.hermes/logs 2>/dev/null || mkdir -p /root/.hermes/logs
sudo chown -R root:root /root/.hermes 2>/dev/null || true
if [ ! -f "$GW_UNIT" ] && [ -x /usr/local/lib/hermes-agent/venv/bin/python ]; then
  echo "[services] hermes-gateway unit missing — recreating standard unit"
  sudo mkdir -p /root/.config/systemd/user
  sudo tee "$GW_UNIT" >/dev/null <<'UNIT'
[Unit]
Description=Hermes Telegram Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HERMES_HOME=/root/.hermes
ExecStart=/usr/local/lib/hermes-agent/venv/bin/python -m hermes_cli.main gateway run
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT
fi
if [ -f /root/.config/systemd/user/hermes-gateway.service ]; then
  echo "[services] found hermes-gateway user service, starting..."
  sudo loginctl enable-linger root >/dev/null 2>&1 || true
  # اطمینان از اجرای user manager
  sudo systemctl start 'user@0.service' >/dev/null 2>&1 || true
  # صبر بیشتر برای ساخته شدن /run/user/0 (قبلاً فقط ۲ ثانیه بود)
  for i in 1 2 3 4 5; do
    if [ -d /run/user/0 ]; then
      echo "[services] /run/user/0 exists after $i tries"
      break
    fi
    echo "[services] waiting for /run/user/0... attempt $i"
    sleep 2
    sudo systemctl start 'user@0.service' >/dev/null 2>&1 || true
  done
  export XDG_RUNTIME_DIR=/run/user/0
  if [ -d "$XDG_RUNTIME_DIR" ]; then
    sudo chown root:root "$XDG_RUNTIME_DIR" 2>/dev/null || true
    sudo chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
    sudo -u root XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user daemon-reload >/dev/null 2>&1 || true
    sudo -u root XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user enable hermes-gateway.service >/dev/null 2>&1 || true
    # تلاش برای استارت
    if sudo -u root XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user start hermes-gateway.service >/dev/null 2>&1; then
      echo "[services] hermes-gateway.service (user): started"
      sleep 2
      sudo -u root XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user status hermes-gateway.service --no-pager -l 2>/dev/null | tail -10 || true
    else
      echo "[services] WARNING: hermes-gateway failed to start via user service, trying direct fallback..."
      sudo -u root XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user status hermes-gateway.service --no-pager -l 2>/dev/null | tail -20 || true
      # Fallback: اجرای مستقیم gateway اگر venv موجود باشد
      if [ -x /usr/local/lib/hermes-agent/venv/bin/python ]; then
        echo "[services] fallback: starting gateway directly via python..."
        sudo -u root bash -c 'XDG_RUNTIME_DIR=/run/user/0 nohup /usr/local/lib/hermes-agent/venv/bin/python -m hermes_cli.main gateway run >/var/log/hermes-gateway.log 2>&1 &' || true
        sleep 3
        if pgrep -f "hermes_cli.*gateway" >/dev/null 2>&1; then
          echo "[services] hermes-gateway: fallback direct start OK"
        else
          echo "[services] WARNING: fallback direct start also failed, checking log..."
          tail -20 /var/log/hermes-gateway.log 2>/dev/null || true
          fail=1
        fi
      else
        echo "[services] WARNING: venv not found at /usr/local/lib/hermes-agent/venv/bin/python — cannot fallback"
        ls -la /usr/local/lib/hermes-agent/ 2>/dev/null | head -n 20 || echo "no hermes-agent dir"
        fail=1
      fi
    fi
  else
    echo "[services] WARNING: /run/user/0 missing after 10s — gateway skipped (non-fatal)"
    echo "[services] trying to start user@0 again..."
    sudo systemctl restart 'user@0.service' >/dev/null 2>&1 || true
    sleep 3
    ls -la /run/user/ 2>/dev/null || echo "no /run/user"
    fail=1
  fi
else
  echo "[services] hermes-gateway.service: unit file absent — skip"
fi

# --- راستی‌آزمایی ---
echo "[services] status:"
sudo systemctl is-active hermes-dashboard.service hermes-tunnel.service 2>/dev/null || true
sudo -u root XDG_RUNTIME_DIR=/run/user/0 systemctl --user is-active hermes-gateway.service 2>/dev/null || echo "gateway user service not active (checking pgrep fallback...)"
pgrep -a -f "hermes.*gateway\|hermes_cli.*gateway" 2>/dev/null || echo "no gateway pgrep"

if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ':9119'; then
  echo "[services] dashboard port 9119: LISTENING"
else
  echo "[services] dashboard port 9119: not listening (yet) - may need more time"
fi

if [ "$fail" -ne 0 ]; then
  echo "[services] DONE with warnings (boot continues)"
else
  echo "[services] DONE — all requested services started"
fi
exit 0
