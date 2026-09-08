#!/bin/bash
# ============================================================================
# tailscale-setup.sh — نصب Tailscale، برقراری اتصال پایدار و حفظ IP ثابت
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS_HOSTNAME="${TS_HOSTNAME:-linux-server-vps}"
TS_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"
TS_API_TOKEN="${TAILSCALE_API_TOKEN:-NOT_SET}"

if [ -z "$TS_AUTH_KEY" ] || [ "$TS_AUTH_KEY" = "NOT_SET" ]; then
  echo "[tailscale] TAILSCALE_AUTH_KEY not set — skipping Tailscale connection."
  exit 0
fi

echo "[tailscale] Checking / Installing Tailscale..."
if ! command -v tailscale &>/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi

# راه‌اندازی سرویس tailscaled
sudo systemctl enable --now tailscaled || sudo systemctl restart tailscaled || true

# برقراری اتصال
echo "[tailscale] Joining Tailnet as '${TS_HOSTNAME}'..."
if [ -f /var/lib/tailscale/tailscaled.state ] && sudo tailscale status &>/dev/null; then
  echo "[tailscale] Existing Tailscale identity detected. Reconnecting..."
  sudo tailscale up --hostname="${TS_HOSTNAME}" --ssh --accept-routes || true
else
  echo "[tailscale] Authenticating with Tailscale Auth Key..."
  sudo tailscale up --authkey="${TS_AUTH_KEY}" --hostname="${TS_HOSTNAME}" --ssh --accept-routes || true
fi

# انتظار برای آنلاین شدن Node
echo "[tailscale] Waiting for node to become online..."
for i in $(seq 1 30); do
  if sudo tailscale status --json 2>/dev/null | jq -e '.Self.Online == true' >/dev/null 2>&1; then
    echo "[tailscale] Connected and online!"
    break
  fi
  sleep 2
done

# پاک‌سازی امن دستگاه‌های مرده/آفلاین در صورت وجود API Token
if [ "$TS_API_TOKEN" != "NOT_SET" ] && [ -n "$TS_API_TOKEN" ]; then
  python3 "$SCRIPT_DIR/tailscale_cleanup.py" || echo "[tailscale] Stale node cleanup skipped."
fi

# استخراج و ثبت IP در متغیر محیطی workflow
TS_IP=$(sudo tailscale ip -4 2>/dev/null || echo "pending")
echo "[tailscale] Active Tailscale IP: ${TS_IP}"
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "TS_IP=${TS_IP}" >> "$GITHUB_ENV"
fi

echo "[tailscale] Current Tailscale Status:"
sudo tailscale status || true
