#!/bin/bash
set -euo pipefail

echo "=== RESTORING PERSISTENT STATE ==="

mkdir -p /tmp/restore
rm -rf /tmp/restore/* || true

# If archive exists, restore it
if [ -f persistent/state.tar.gz ]; then
  echo "Restoring from persistent/state.tar.gz"
  tar -xzf persistent/state.tar.gz -C /tmp/restore || echo "Archive empty or corrupted"
else
  echo "No persistent archive found — using local persistent/data/"
  cp -r persistent/data/* /tmp/restore/ 2>/dev/null || echo "No local data to restore"
fi

# Restore packages
if [ -f /tmp/restore/packages.list ]; then
  echo "Package list restored: $(cat /tmp/restore/packages.list | wc -l) packages"
fi

# Restore SSH config
if [ -f /tmp/restore/etc/ssh/sshd_config ]; then
  sudo cp /tmp/restore/etc/ssh/sshd_config /etc/ssh/sshd_config || echo "Failed to restore SSH config"
fi

# Restore user data
if [ -d /tmp/restore/home/Hamid ]; then
  sudo rsync -av /tmp/restore/home/Hamid/ /home/Hamid/ || echo "Partial user data restore"
  sudo chown -R Hamid:Hamid /home/Hamid || true
  echo "User data restored"
fi

echo "=== RESTORE COMPLETE ==="
ls -la /tmp/restore/
