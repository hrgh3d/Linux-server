#!/bin/bash
# ============================================================================
# ssh_selftest.sh — تست end-to-end محلی SSH (v4)
#  برای اطمینان از: sshd در حال اجراست، ورود با کلید کار می‌کند،
#  sudo بدون رمز و `sudo su` بدون درخواست پسورد در دسترس است، و ورود root با کلید.
#  از یک کلید موقت استفاده می‌کند و در پایان authorized_keys را به حالت
#  فقط-کلید-ثابت برمی‌گرداند (حتی اگر تست خطا بدهد).
# ============================================================================
set -uo pipefail

echo "[ssh-test] ====== SSH self test (localhost) ====="
WORK=$(mktemp -d)
TEMP_KEY="$WORK/testkey"
TEMP_PUB=""
CLEANUP_DONE=0

cleanup() {
  [ "$CLEANUP_DONE" = "1" ] && return
  CLEANUP_DONE=1
  # حذف کلید موقت از authorized_keys ها
  if [ -n "$TEMP_PUB" ]; then
    for ak in /home/Hamid/.ssh/authorized_keys /root/.ssh/authorized_keys; do
      sudo sed -i "\#$TEMP_PUB#d" "$ak" 2>/dev/null || true
    done
    echo "[ssh-test] removed temporary key from authorized_keys"
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N '' -f "$TEMP_KEY" -C "linux-server-selftest"
TEMP_PUB="$(cat "$TEMP_KEY.pub")"
echo "[ssh-test] temporary key: $TEMP_PUB"

# ثبت کلید موقت برای Hamid و root (به صورت موقت)
for ak in /home/Hamid/.ssh/authorized_keys /root/.ssh/authorized_keys; do
  [ -f "$ak" ] || { sudo mkdir -p "$(dirname "$ak")"; sudo touch "$ak"; }
  echo "$TEMP_PUB" | sudo tee -a "$ak" >/dev/null
  sudo chmod 600 "$ak"
done

SSH_OPTS=(-i "$TEMP_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
          -o UserKnownHostsFile="$WORK/known_hosts" -o ConnectTimeout=10)
FAIL=0

# 1) ورود Hamid با کلید
echo "[ssh-test] 1) ssh Hamid@127.0.0.1 ..."
OUT=$(ssh "${SSH_OPTS[@]}" Hamid@127.0.0.1 'id -un' 2>&1) && echo "   ok: user=$OUT" || { echo "   FAIL: $OUT"; FAIL=1; }

# 2) sudo بدون رمز برای Hamid
echo "[ssh-test] 2) passwordless sudo ..."
OUT=$(ssh "${SSH_OPTS[@]}" Hamid@127.0.0.1 'sudo -n id -u' 2>&1) && echo "   ok: uid=$OUT" || { echo "   FAIL: $OUT"; FAIL=1; }

# 3) sudo su بدون درخواست پسورد
echo "[ssh-test] 3) passwordless 'sudo su' ..."
OUT=$(ssh "${SSH_OPTS[@]}" Hamid@127.0.0.1 'sudo -n su -c "id -u; whoami"' 2>&1) && echo "   ok: $OUT" || { echo "   FAIL: $OUT"; FAIL=1; }

# 4) ورود root با کلید (prohibit-password)
echo "[ssh-test] 4) ssh root@127.0.0.1 ..."
OUT=$(ssh "${SSH_OPTS[@]}" root@127.0.0.1 'id -u' 2>&1) && echo "   ok: uid=$OUT" || { echo "   FAIL: $OUT"; FAIL=1; }

echo "[ssh-test] result: $([ $FAIL -eq 0 ] && echo PASS || echo FAIL)"
exit $FAIL
