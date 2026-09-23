#!/usr/bin/env bash
# نصب AI Hub روی سرور. idempotent است — چندبار اجرا مشکلی ندارد.
set -euo pipefail
DEST=/opt/aihub
PORT=9446

echo "== 1) copy files =="
mkdir -p "$DEST"
# فایل‌ها از ریپو کپی می‌شوند (مسیر منبع را SRC بده یا کنار همین اسکریپت بگذار)
SRC="${SRC:-$(cd "$(dirname "$0")" && pwd)}"
cp -r "$SRC/app" "$SRC/static" "$SRC/requirements.txt" "$DEST"/

echo "== 2) venv =="
if [ ! -x "$DEST/venv/bin/python" ]; then
  python3 -m venv "$DEST/venv"
fi
"$DEST/venv/bin/pip" -q install --upgrade pip
"$DEST/venv/bin/pip" -q install -r "$DEST/requirements.txt"

echo "== 3) systemd unit =="
cat > /etc/systemd/system/aihub.service <<UNIT
[Unit]
Description=AI Hub - unified control panel for all AI programs
After=network-online.target 9router.service
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$DEST
# متغیرهای مشترک کلاینت‌های AI را لازم داریم (ANTHROPIC_BASE_URL و غیره)
EnvironmentFile=-/etc/profile.d/ai-clients.sh
Environment=PYTHONUNBUFFERED=1
Environment=XDG_RUNTIME_DIR=/run/user/0
ExecStart=$DEST/venv/bin/uvicorn app.main:app --host 127.0.0.1 --port $PORT --no-access-log
Restart=always
RestartSec=5
# محافظت: اگر hub بمیرد هیچ سرویس دیگری را با خود پایین نمی‌کشد
KillMode=mixed
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now aihub.service
sleep 4
systemctl is-active aihub.service || { journalctl -u aihub -n 30 --no-pager; exit 1; }

echo "== 4) tailscale serve on $PORT =="
tailscale serve --bg --https=$PORT http://127.0.0.1:$PORT || true

echo "== 5) smoke test =="
curl -s -m 10 http://127.0.0.1:$PORT/api/health && echo
echo "OK -> https://linux-server-vps.tail3641f4.ts.net:$PORT"
