#!/bin/bash
# ============================================================================
# ssh_configure.sh — پیکربندی SSH با کلید ثابت (v4)
#  - نصب sshd_config استاندارد مخزن
#  - تضمین وجود کلیدهای Host و چاپ اثرانگشت آن‌ها (ثبات هویت سرور)
#  - افزودن (merge) کلید عمومی ثابت به authorized_keys کاربر Hamid و root
#    بدون حذف کلیدهای اضافی‌ای که کاربر قبلاً مجاز کرده است.
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_PUB="$SCRIPT_DIR/../ssh/id_ed25519.pub"

if [ ! -f "$REPO_PUB" ]; then
  echo "[ssh] ERROR: fixed public key not found at $REPO_PUB"
  exit 1
fi
FIXED_KEY="$(tr -d '\r\n' < "$REPO_PUB")"

echo "[ssh] installing sshd_config..."
sudo cp "$SCRIPT_DIR/../config/sshd_config" /etc/ssh/sshd_config
sudo chown root:root /etc/ssh/sshd_config
sudo chmod 644 /etc/ssh/sshd_config

# کلیدهای Host در صورت نبود (اولین بوت) — سپس همیشه در state ذخیره می‌شوند
if ! ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
  echo "[ssh] generating SSH host keys (first boot)..."
  sudo ssh-keygen -A
fi
sudo chown root:root /etc/ssh/ssh_host_* 2>/dev/null || true
sudo chmod 600 /etc/ssh/ssh_host_*_key 2>/dev/null || true
sudo chmod 644 /etc/ssh/ssh_host_*_key.pub 2>/dev/null || true

# افزودن کلید ثابت به authorized_keys کاربر Hamid (بدون حذف کلیدهای قبلی)
ensure_key() {
  local user="$1" home="$2"
  sudo mkdir -p "$home/.ssh"
  sudo touch "$home/.ssh/authorized_keys"
  sudo chmod 700 "$home/.ssh"
  sudo chmod 600 "$home/.ssh/authorized_keys"
  if ! sudo grep -qxF "$FIXED_KEY" "$home/.ssh/authorized_keys" 2>/dev/null; then
    echo "$FIXED_KEY" | sudo tee -a "$home/.ssh/authorized_keys" >/dev/null
    echo "[ssh] added fixed key to $user authorized_keys"
  else
    echo "[ssh] fixed key already present for $user"
  fi
  # حذف خطوط تکراریِ دقیق
  sudo cp "$home/.ssh/authorized_keys" "$home/.ssh/authorized_keys.tmp"
  sudo awk '!seen[$0]++' "$home/.ssh/authorized_keys.tmp" > /tmp/ak_dedup
  sudo mv /tmp/ak_dedup "$home/.ssh/authorized_keys"
  sudo rm -f "$home/.ssh/authorized_keys.tmp"
  sudo chown -R "$user:$user" "$home/.ssh"
  sudo chmod 700 "$home/.ssh"
  sudo chmod 600 "$home/.ssh/authorized_keys"
}

ensure_key "Hamid" "/home/Hamid" || true
ensure_key "root" "/root" || true

echo "[ssh] enabling and restarting sshd..."
sudo systemctl enable ssh 2>/dev/null || true
sudo systemctl restart ssh 2>/dev/null || sudo service ssh restart 2>/dev/null || \
  sudo systemctl restart sshd 2>/dev/null || true

sleep 1
if sudo systemctl is-active ssh >/dev/null 2>&1 || sudo systemctl is-active sshd >/dev/null 2>&1 || \
   pgrep -x sshd >/dev/null 2>&1; then
  echo "[ssh] sshd is running"
else
  echo "[ssh] WARNING: sshd does not seem to be running"
fi

echo "[ssh] sshd config test: $(sudo sshd -t >/dev/null 2>&1 && echo OK || echo FAILED)"
echo "[ssh] listening: $(sudo ss -tlnp 2>/dev/null | grep ':22 ' | head -1 || echo 'port 22 not listening')"
echo "[ssh] host key fingerprints:"
sudo ssh-keygen -lf /etc/ssh/ssh_host_*_key 2>/dev/null | sed 's/^/[ssh]   /' || true
echo "[ssh] authorized_keys (Hamid) lines: $(sudo wc -l < /home/Hamid/.ssh/authorized_keys 2>/dev/null || echo 0)"
echo "[ssh] authorized_keys (root) lines: $(sudo wc -l < /root/.ssh/authorized_keys 2>/dev/null || echo 0)"
echo "[ssh] configured."
