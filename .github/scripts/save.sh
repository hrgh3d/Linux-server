#!/bin/bash
set -euo pipefail

echo "=== SAVING PERSISTENT STATE ==="

# Ensure persistent directory exists
mkdir -p persistent/data/home/Hamid/.ssh
mkdir -p persistent/data/etc/ssh
mkdir -p persistent/data/var/log

# 1. Save installed packages
sudo dpkg --get-selections > persistent/packages.list || echo "Failed to save package list"
echo "Package list saved: $(wc -l < persistent/packages.list) packages"

# 2. Save SSH server configuration
sudo cp /etc/ssh/sshd_config persistent/data/etc/ssh/ || echo "SSH config copy failed"

# 3. Save user data and configurations (exclude temporary files)
if [ -d /home/Hamid ]; then
  sudo rsync -av --exclude='.cache' --exclude='tmp' --exclude='*.tmp' /home/Hamid/ persistent/data/home/Hamid/ || echo "User data backup partial failure"
  sudo chown -R $(whoami):$(whoami) persistent/data/home/Hamid/ 2>/dev/null || true
fi

# 4. Save system settings (key configs only to avoid bloat)
for conf in sshd_config sudoers sudoers.d/hamid; do
  if [ -f "/etc/$conf" ]; then
    sudo mkdir -p "persistent/data/etc/$(dirname $conf)"
    sudo cp "/etc/$conf" "persistent/data/etc/$conf" || true
  fi
done

# 5. Fix permissions before archive (prevent tar/git errors) - use sudo
sudo chmod -R +r persistent/data/ || true
sudo find persistent/data -type f -exec chmod 644 {} \; 2>/dev/null || true
sudo find persistent/data -type d -exec chmod 755 {} \; 2>/dev/null || true

# 6. Create compressed archive
cd persistent/data || exit 1
tar -czf ../../state.tar.gz . || echo "Archive creation failed (some files may be skipped)"
cd ../..
echo "Archive created: $(ls -lh persistent/state.tar.gz)"

# 6. Commit back to repository using GITHUB_TOKEN (automatic in Actions)
if [ -n "${GITHUB_TOKEN:-}" ]; then
  git config --global user.email "linux-server-bot@github.com"
  git config --global user.name "Linux Server Auto-Save"
  # Fix permissions before git operations (use sudo for root-owned files)
  sudo chmod -R +r persistent/ || true
  # Add changes
  git add persistent/ || true
  # Check if there are changes
  if git diff --cached --quiet; then
    echo "No changes to commit"
  else
    git commit -m "Auto-save persistent state: $(date '+%Y-%m-%d %H:%M:%S') — packages: $(wc -l < persistent/packages.list)" || echo "Commit skipped (no changes)"
    # Push using GITHUB_TOKEN embedded in remote URL
    git push https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git HEAD:${GITHUB_REF_NAME} || echo "Push failed (token may lack contents:write) — state saved locally in persistent/state.tar.gz"
    echo "State committed to repository"
  fi
else
  echo "GITHUB_TOKEN not set — state saved locally only (persistent/state.tar.gz)"
fi

echo "=== PERSISTENT STATE SAVED ==="
ls -lh persistent/state.tar.gz
