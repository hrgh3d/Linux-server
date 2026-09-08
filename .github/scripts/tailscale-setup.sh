#!/bin/bash
# ============================================================================
# tailscale-setup.sh — اتصال خودکار و پایدار Tailscale (v4)
#
# استراتژی حفظ IP/هویت ثابت:
#   ۱) اگر state بازیابی شده باشد (/var/lib/tailscale/tailscaled.state)، ابتدا
#      بدون Auth Key با همان هویت قبلی (Node Key) reconnect می‌شود => همان
#      Node و همان IP قبلی در Tailnet.
#   ۲) فقط اگر هویتی وجود نداشت، با TAILSCALE_AUTH_KEY احراز می‌شود.
#   ۳) سپس IP واقعی با TAILSCALE_FIXED_IP مقایسه می‌شود و در صورت نیاز از طریق
#      Tailscale API روی همان IP ثابت pin می‌شود.
#   ۴) پاک‌سازی nodeهای تکراری/مرده هم‌نام (فقط آفلاین‌ها) + اصلاح hostname.
# خروجی: TS_IP به GITHUB_ENV نوشته می‌شود.
# ============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TS_HOSTNAME="${TS_HOSTNAME:-linux-server-vps}"
TS_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"
TS_API_TOKEN="${TAILSCALE_API_TOKEN:-NOT_SET}"
TS_FIXED_IP="${TAILSCALE_FIXED_IP:-}"

if [ -z "$TS_AUTH_KEY" ] || [ "$TS_AUTH_KEY" = "NOT_SET" ]; then
  echo "[tailscale] TAILSCALE_AUTH_KEY is not set — cannot join tailnet."
  echo "[tailscale] SSH will still run, but the server will not be reachable via Tailscale."
  if [ -n "${GITHUB_ENV:-}" ]; then echo "TS_IP=unavailable" >> "$GITHUB_ENV"; fi
  exit 0
fi

echo "[tailscale] ensuring tailscale is installed..."
if ! command -v tailscale &>/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh || true
fi

# اطمینان از اجرای سرویس tailscaled (بدون دست‌زدن به /var/lib/tailscale بازیابی‌شده)
if command -v systemctl &>/dev/null && sudo systemctl list-unit-files tailscaled >/dev/null 2>&1; then
  sudo systemctl enable tailscaled >/dev/null 2>&1 || true
  sudo systemctl start tailscaled >/dev/null 2>&1 || sudo systemctl restart tailscaled >/dev/null 2>&1 || true
else
  # fallback: اجرای مستقیم tailscaled
  if ! pgrep -x tailscaled >/dev/null 2>&1; then
    sudo mkdir -p /var/lib/tailscale
    sudo nohup tailscaled --state=/var/lib/tailscale/tailscaled.state >/var/log/tailscaled.log 2>&1 &
    sleep 2
  fi
fi

# کمی صبر برای بالا آمدن سوکت
for _ in $(seq 1 15); do
  sudo tailscale status >/dev/null 2>&1 && break
  sleep 1
done

UP_FLAGS=(--hostname="${TS_HOSTNAME}" --ssh --accept-routes)

IDENTITY_PRESENT=0
if [ -s /var/lib/tailscale/tailscaled.state ]; then
  IDENTITY_PRESENT=1
  echo "[tailscale] Restored Tailscale identity detected. Reconnecting without a new auth..."
  if sudo tailscale up "${UP_FLAGS[@]}" >/tmp/ts_up.log 2>&1; then
    echo "[tailscale] reconnect OK (same node key)"
  else
    echo "[tailscale] reconnect failed ($(tail -1 /tmp/ts_up.log)); will authenticate with auth key."
    IDENTITY_PRESENT=0
    if sudo tailscale up "${UP_FLAGS[@]}" --authkey="${TS_AUTH_KEY}" >/tmp/ts_up2.log 2>&1; then
      echo "[tailscale] authenticated with auth key (new node — identity was not reusable)."
    else
      echo "[tailscale] ERROR: tailscale up failed: $(tail -2 /tmp/ts_up2.log)"
    fi
  fi
else
  echo "[tailscale] No saved identity — authenticating with TAILSCALE_AUTH_KEY..."
  sudo tailscale up "${UP_FLAGS[@]}" --authkey="${TS_AUTH_KEY}" >/tmp/ts_up3.log 2>&1 || \
    echo "[tailscale] WARNING: tailscale up returned non-zero: $(tail -2 /tmp/ts_up3.log)"
fi

# انتظار تا آنلاین شدن و گرفتن IP
IP=""
for i in $(seq 1 45); do
  ONLINE=$(sudo tailscale status --json 2>/dev/null | jq -r '.Self.Online // false' 2>/dev/null || echo false)
  IP=$(sudo tailscale ip -4 2>/dev/null | head -1 || true)
  if [ "$ONLINE" = "true" ] && [ -n "$IP" ]; then
    echo "[tailscale] online after ~$((i*2))s, IPv4=$IP"
    break
  fi
  sleep 2
done
[ -z "$IP" ] && IP=$(sudo tailscale ip -4 2>/dev/null | head -1 || echo "pending")
echo "[tailscale] Current IPv4: ${IP}"

# ---- پاک‌سازی Nodeهای مرده/تکراری (قبل از تثبیت IP تا IP آزاد شود)
if [ "$TS_API_TOKEN" != "NOT_SET" ] && [ -n "$TS_API_TOKEN" ]; then
  python3 "$SCRIPT_DIR/tailscale_cleanup.py" || echo "[tailscale] stale-node cleanup skipped."
fi

# ---- تثبیت IP از طریق Tailscale API (فقط اگر FIXED_IP تنظیم شده و متفاوت باشد)
if [ -n "$TS_FIXED_IP" ] && [ "$TS_FIXED_IP" != "NOT_SET" ] && \
   [ "$TS_API_TOKEN" != "NOT_SET" ] && [ -n "$TS_API_TOKEN" ]; then
  if [ "$IP" != "$TS_FIXED_IP" ]; then
    echo "[tailscale] IP ${IP} != desired ${TS_FIXED_IP}; trying to pin via API..."
    SELF_NODEKEY=$(sudo tailscale status --json 2>/dev/null | jq -r '.Self.PublicKey // .Self.NodeKey // empty' 2>/dev/null || true)
    SELF_ADDRS=$(sudo tailscale status --json 2>/dev/null | jq -r '[.Self.TailscaleIPs[]] | join(",")' 2>/dev/null || true)
    DEV_ID=""
    DEV_JSON=$(curl -sS --max-time 20 -H "Authorization: Bearer ${TS_API_TOKEN}" \
      "https://api.tailscale.com/api/v2/tailnet/-/devices?fields=all" 2>/dev/null || echo '{}')
    if [ -n "$SELF_NODEKEY" ]; then
      DEV_ID=$(echo "$DEV_JSON" | jq -r --arg k "$SELF_NODEKEY" '.devices[] | select(.nodeKey == $k) | .id' 2>/dev/null | head -1)
    fi
    if [ -z "$DEV_ID" ] && [ -n "$SELF_ADDRS" ]; then
      DEV_ID=$(echo "$DEV_JSON" | jq -r --arg a "$SELF_ADDRS" \
        '.devices[] | select((.addresses | join(",")) == $a) | .id' 2>/dev/null | head -1)
    fi
    if [ -n "$DEV_ID" ]; then
      RESP=$(curl -sS --max-time 20 -X POST -H "Authorization: Bearer ${TS_API_TOKEN}" \
        -H "Content-Type: application/json" \
        "https://api.tailscale.com/api/v2/device/${DEV_ID}/ip" \
        -d "{\"ipv4\":\"${TS_FIXED_IP}\"}" -w '\nHTTP:%{http_code}' 2>/dev/null || true)
      echo "[tailscale] pin API response: $(echo "$RESP" | tail -1)"
      sleep 5
      IP=$(sudo tailscale ip -4 2>/dev/null | head -1 || echo "$IP")
      echo "[tailscale] IPv4 after pin attempt: ${IP}"
    else
      echo "[tailscale] WARNING: could not map local node to API device for IP pinning"
    fi
  else
    echo "[tailscale] IP already equals desired ${TS_FIXED_IP}"
  fi
else
  echo "[tailscale] no fixed IP pinning (TAILSCALE_FIXED_IP or API token not set) — identity restore keeps IP"
fi

TS_IP="$IP"
echo "[tailscale] FINAL IPv4 = ${TS_IP}"
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "TS_IP=${TS_IP}" >> "$GITHUB_ENV"
fi

echo "[tailscale] status:"
sudo tailscale status || true
