#!/bin/bash
set -euo pipefail

echo "=== RESTORING PERSISTENT STATE ==="

mkdir -p /tmp/restore
rm -rf /tmp/restore/* || true

# FIRST: Restore from SAFE directory (separate persistence — survives cancel/restart)
if [ -d persistent/safe ]; then
  echo "Restoring from SAFE persistent directory (separate from archive)"
  cp -r persistent/safe/* /tmp/restore/ 2>/dev/null || echo "Safe directory partial restore"
fi

# SECOND: Restore from archive (additional data)
if [ -f persistent/state.tar.gz ]; then
  echo "Restoring from persistent/state.tar.gz"
  tar -xzf persistent/state.tar.gz -C /tmp/restore || echo "Archive empty or corrupted"
else
  echo "No persistent archive found — using local persistent/data/"
  cp -r persistent/data/* /tmp/restore/ 2>/dev/null || echo "No local data to restore"
fi

# Restore packages (from archive packages/packages.list or packages.list)
if [ -f /tmp/restore/packages/packages.list ]; then
  echo "Package list restored: $(cat /tmp/restore/packages/packages.list | wc -l) packages"
  cp /tmp/restore/packages/packages.list persistent/packages.list || echo "Failed to save package list locally"
elif [ -f /tmp/restore/packages.list ]; then
  echo "Package list restored: $(cat /tmp/restore/packages.list | wc -l) packages"
  cp /tmp/restore/packages.list persistent/packages.list || echo "Failed to save package list locally"
fi

# Restore SSH config + private SSH key
if [ -f /tmp/restore/etc/ssh/sshd_config ]; then
  sudo cp /tmp/restore/etc/ssh/sshd_config /etc/ssh/sshd_config || echo "Failed to restore SSH config"
fi

# Restore private SSH key (same as System 1)
if [ -f /tmp/restore/ssh/id_ed25519 ]; then
  mkdir -p .github/ssh
  cp /tmp/restore/ssh/id_ed25519 .github/ssh/id_ed25519 || echo "Failed to restore private SSH key"
  chmod 600 .github/ssh/id_ed25519 || true
  echo "Private SSH key restored"
fi
if [ -f /tmp/restore/ssh/id_ed25519.pub ]; then
  mkdir -p .github/ssh
  cp /tmp/restore/ssh/id_ed25519.pub .github/ssh/id_ed25519.pub || echo "Failed to restore public SSH key"
  echo "Public SSH key restored"
fi

# Restore user data
if [ -d /tmp/restore/home/Hamid ]; then
  sudo rsync -av /tmp/restore/home/Hamid/ /home/Hamid/ || echo "Partial user data restore"
  sudo chown -R Hamid:Hamid /home/Hamid || true
  echo "User data restored"
fi

echo "=== RESTORE COMPLETE ==="
ls -la /tmp/restore/
