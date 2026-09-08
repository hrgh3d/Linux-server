#!/bin/bash
# ============================================================================
# tailscale-setup.sh — نصب Tailscale، اتصال به tailnet، پاک‌سازی nodeهای قدیمی
# و تثبیت IP ثابت.
#
# چرا IP ثابت است؟
#   هر run یک node جدید می‌سازد و Tailscale به آن IP تازه می‌دهد. این اسکریپت
#   با Tailscale API:
#     1) nodeهای قدیمیِ هم‌نام (مثلاً linux-server-vps-1) را حذف می‌کند،
#     2) نام دقیق hostname را روی node جدید اعمال می‌کند،
#     3) IP مشخص‌شده (TAILSCALE_FIXED_IP) را روی node جدید تثبیت می‌کند.
#
# متغیرهای موردنیاز (از workflow):
#   TAILSCALE_AUTH_KEY، TAILSCALE_API_TOKEN (اختیاری)، TAILSCALE_FIXED_IP
# خروجی:
#   TS_IP را در GITHUB_ENV می‌نویسد.
# ============================================================================
set -euo pipefail

TS_HOSTNAME="${TS_HOSTNAME:-linux-server-vps}"
TS_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"
TS_API_TOKEN="${TAILSCALE_API_TOKEN:-NOT_SET}"
TS_FIXED_IP="${TAILSCALE_FIXED_IP:-100.100.100.100}"

if [ -z "$TS_AUTH_KEY" ] || [ "$TS_AUTH_KEY" = "NOT_SET" ]; then
  echo "[tailscale] TAILSCALE_AUTH_KEY not set — skipping (server will not join tailnet)"
  exit 0
fi

echo "[tailscale] installing..."
curl -fsSL https://tailscale.com/install.sh | sh

echo "[tailscale] joining tailnet as '${TS_HOSTNAME}'"
sudo tailscale up --authkey="${TS_AUTH_KEY}" --hostname="${TS_HOSTNAME}" --ssh \
  || echo "[tailscale] up returned non-zero (may already be up)"

# صبر تا آنلاین شدن node
for _ in $(seq 1 30); do
  if sudo tailscale status --json 2>/dev/null | jq -e '.Self.Online == true' >/dev/null 2>&1; then
    break
  fi
  sleep 3
done

if [ "$TS_API_TOKEN" != "NOT_SET" ] && [ -n "$TS_API_TOKEN" ]; then
  API="https://api.tailscale.com/api/v2"
  AUTH=(-H "Authorization: Bearer ${TS_API_TOKEN}")

  # شناسهٔ node فعلی (Tailscale ممکن است پیشوند nodeid: داشته باشد)
  SELF_ID=$(sudo tailscale status --json | jq -r '.Self.ID // empty' | sed -E 's/^nodeid://')
  if [ -z "$SELF_ID" ]; then
    SELF_ID=$(curl -sf "${AUTH[@]}" "$API/tailnet/-/devices" 2>/dev/null \
      | jq -r --arg h "$TS_HOSTNAME" '.devices[] | select(.hostname == $h) | .id' | head -n1)
  fi

  if [ -n "$SELF_ID" ]; then
    # 1) حذف nodeهای قدیمیِ هم‌نام
    curl -sf "${AUTH[@]}" "$API/tailnet/-/devices" 2>/dev/null \
      | jq -r --arg id "$SELF_ID" --arg h "$TS_HOSTNAME" \
        '.devices[] | select(.hostname == $h and .id != $id) | .id' \
      | while read -r sid; do
          [ -n "$sid" ] || continue
          echo "[tailscale] removing stale node $sid"
          curl -sf -X DELETE "${AUTH[@]}" "$API/device/$sid" >/dev/null 2>&1 || true
        done

    # 2) اعمال نام دقیق (در صورت افزوده‌شدن پسوند مثل linux-server-vps-1)
    curl -sf -X POST "${AUTH[@]}" "$API/device/$SELF_ID/name" \
      -d "{\"name\":\"${TS_HOSTNAME}\"}" >/dev/null 2>&1 || true

    # 3) تثبیت IP ثابت
    echo "[tailscale] pinning IP ${TS_FIXED_IP}"
    if curl -sf -X POST "${AUTH[@]}" "$API/device/$SELF_ID/ip" \
      -d "{\"ipv4\":\"${TS_FIXED_IP}\"}" >/dev/null 2>&1; then
      echo "[tailscale] IP pinned to ${TS_FIXED_IP}"
    else
      echo "[tailscale] WARNING: could not pin IP — check TAILSCALE_API_TOKEN scopes (devices read/write)"
    fi
  else
    echo "[tailscale] WARNING: could not determine device id"
  fi
else
  echo "[tailscale] TAILSCALE_API_TOKEN not set — IP will not be pinned (hostname may get a suffix)"
fi

sleep 5
TS_IP=$(sudo tailscale ip -4 2>/dev/null || echo "pending")
echo "[tailscale] IP = ${TS_IP}"
echo "TS_IP=${TS_IP}" >> "$GITHUB_ENV"
echo "[tailscale] status:"
sudo tailscale status || true
