#!/bin/bash
# ============================================================================
# tailscale-setup.sh — اتصال Tailscale با هویت پایدار (v6.9.2)
#  - v6.9.2: حذف google-chrome repo قبل از apt update (جلوگیری از Hash Sum mismatch)
#  - تلاش برای reconnect با هویت قبلی (state) و fallback به auth key
# ============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TS_AUTH_KEY="${TAILSCALE_AUTH_KEY:-NOT_SET}"
TS_API_TOKEN="${TAILSCALE_API_TOKEN:-NOT_SET}"
TS_HOSTNAME="${TS_HOSTNAME:-linux-server-vps}"
TS_FIXED_IP="${TAILSCALE_FIXED_IP:-}"
MARKER="/root/.ts-node-owned"

log() { echo "[tailscale] $*"; }

# ---- پاکسازی repo معیوب google-chrome که باعث Hash Sum mismatch می‌شود ----
if [ -f /etc/apt/sources.list.d/google-chrome.list ]; then
  log "removing broken google-chrome repo to avoid apt hash mismatch..."
  sudo rm -f /etc/apt/sources.list.d/google-chrome.list || true
fi
if [ -f /etc/apt/sources.list.d/google-chrome.list.distUpgrade ]; then
  sudo rm -f /etc/apt/sources.list.d/google-chrome.list.distUpgrade || true
fi

# ---- نصب tailscale اگر نیست ----
ensure_tailscale() {
  if command -v tailscale >/dev/null 2>&1 && command -v tailscaled >/dev/null 2>&1; then
    log "tailscale already installed"
    return 0
  fi
  log "ensuring tailscale is installed..."
  # تلاش با اسکریپت رسمی، با retry و حذف chrome repo
  for attempt in 1 2 3; do
    log "tailscale install attempt $attempt..."
    # پاکسازی دوباره قبل از هر تلاش
    sudo rm -f /etc/apt/sources.list.d/google-chrome.list || true
    # اجرای installer رسمی
    if curl -fsSL --max-time 60 https://tailscale.com/install.sh | sh; then
      log "tailscale installed via official script"
      return 0
    fi
    log "official script failed, trying apt method..."
    sudo mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null || true
    sudo chmod 0644 /usr/share/keyrings/tailscale-archive-keyring.gpg || true
    curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null || true
    sudo chmod 0644 /etc/apt/sources.list.d/tailscale.list || true
    # apt update با ignore برای chrome repo باقی‌مانده
    sudo apt-get update -y || sudo apt-get update -y --allow-releaseinfo-change || true
    if sudo apt-get install -y tailscale; then
      log "tailscale installed via apt"
      return 0
    fi
    log "apt install failed, retrying in 10s..."
    sleep 10
  done
  log "ERROR: tailscale installation failed after 3 attempts"
  return 1
}

if ! ensure_tailscale; then
  log "ERROR: cannot install tailscale — aborting"
  exit 1
fi

# ---- اطمینان از اجرای tailscaled ----
if ! pgrep -x tailscaled >/dev/null 2>&1; then
  log "starting tailscaled..."
  sudo mkdir -p /var/lib/tailscale
  sudo systemctl enable --now tailscaled >/dev/null 2>&1 || {
    sudo pkill -x tailscaled >/dev/null 2>&1 || true
    sleep 1
    sudo nohup tailscaled --state=/var/lib/tailscale/tailscaled.state >/var/log/tailscaled.log 2>&1 &
    sleep 2
  }
fi

sleep 2

# ---- تابع up ----
do_tailscale_up() {
  local extra_args="$1"
  local logfile="/tmp/ts_up_$(date +%s).log"
  log "running: tailscale up $extra_args (log $logfile, bounded 150s)"
  # v6.9.3: 'tailscale up' blocks INDEFINITELY when the node needs re-auth,
  # waits on admin approval, or hits a name-collision (seen 2026-09-10: a
  # reconnect hung 15m until the step timeout, killing a healthy restore).
  # Bound it, then verify via 'tailscale status' — the node may be online
  # even if 'up' itself is stuck.
  # v6.10: WITHOUT --accept-routes: the node must NOT advertise the GitHub
  # runner's internal (172.x) subnets to the tailnet — that gave every
  # tailnet device routes into GitHub infrastructure and was never needed
  # for SSH. Plain node-to-node connectivity is unaffected.
  # shellcheck disable=SC2086
  if timeout 150 sudo tailscale up --hostname="$TS_HOSTNAME" $extra_args >"$logfile" 2>&1; then
    log "tailscale up OK"
    cat "$logfile"
    return 0
  else
    local rc=$?
    log "tailscale up did not return cleanly (rc=$rc):"
    tail -20 "$logfile" 2>/dev/null || true
    if timeout 30 sudo tailscale status --json 2>/dev/null | jq -e '.Self.Online == true' >/dev/null 2>&1; then
      log "'up' blocked but node IS online per status — proceeding"
      return 0
    fi
    log "diagnostics — tailscale status while offline:"
    timeout 30 sudo tailscale status 2>&1 | head -20 || true
    return 1
  fi
}

# ---- منطق اتصال ----
IP="pending"

# اگر marker وجود دارد، یعنی قبلاً این node مال ما بوده — سعی reconnect بدون auth
if [ -f "$MARKER" ] && [ -s /var/lib/tailscale/tailscaled.state ]; then
  log "Our identity (marker) restored — reconnecting without a new auth..."
  if do_tailscale_up ""; then
    IP=$(sudo tailscale ip -4 2>/dev/null | head -1 || echo "pending")
    log "reconnected, IP=$IP"
  else
    log "reconnect failed ($(cat /tmp/ts_up_*.log 2>/dev/null | tail -1)); authenticating with auth key."
  fi
fi

# اگر هنوز pending، با auth key احراز هویت
if [ "$IP" = "pending" ] || [ -z "$IP" ]; then
  if [ "$TS_AUTH_KEY" = "NOT_SET" ] || [ -z "$TS_AUTH_KEY" ]; then
    log "ERROR: no TAILSCALE_AUTH_KEY and no restored identity — cannot connect"
    exit 1
  fi
  log "authenticating with TAILSCALE_AUTH_KEY..."
  # حذف کلیدهای قدیمی اگر Tailscale قبلاً با کلید دیگری بالا آمده
  if ! do_tailscale_up "--authkey=${TS_AUTH_KEY}"; then
    log "first up failed, trying with --reset..."
    if ! do_tailscale_up "--authkey=${TS_AUTH_KEY} --reset"; then
      log "ERROR: tailscale up failed even with --reset"
      # لاگ نهایی
      sudo tailscale status 2>&1 | head -20 || true
      exit 1
    fi
  fi
  IP=$(sudo tailscale ip -4 2>/dev/null | head -1 || echo "pending")
  log "authenticated, IP=$IP"
fi

# صبر برای آنلاین شدن
for i in 1 2 3 4 5; do
  sleep 3
  ONLINE=$(sudo tailscale status --json 2>/dev/null | jq -r '.Self.Online // false' 2>/dev/null || echo false)
  IP=$(sudo tailscale ip -4 2>/dev/null | head -1 || echo "pending")
  log "check $i: online=$ONLINE ip=$IP"
  if [ "$ONLINE" = "true" ] && [ -n "$IP" ] && [ "$IP" != "pending" ]; then
    break
  fi
done

echo "TS_IP=$IP" >> "$GITHUB_ENV" 2>/dev/null || true
echo "IP=$IP" > /tmp/ts_ip.txt
export TS_IP="$IP"

log "Current IPv4: ${IP}"

if [ -z "$IP" ] || [ "$IP" = "pending" ]; then
  log "ERROR: node did not come online (no Tailscale IPv4)."
  log "diagnostics — daemon state:"
  sudo tailscale status 2>&1 | head -20 || true
  log "diagnostics — last up output:"
  cat /tmp/ts_up*.log 2>/dev/null | tail -20 || true
  log "hint: if the log says 'invalid key'/'expired', rotate TAILSCALE_AUTH_KEY (use a reusable, non-expiring key)."
  bash "$SCRIPT_DIR/notify.sh" --type server --stage tailscale-online \
    --error "Tailscale node did not come online (IPv4=pending). Last up: $(cat /tmp/ts_up*.log 2>/dev/null | tail -2 | tr '\n' ' ') " || true
  exit 1
fi

if [ -s /var/lib/tailscale/tailscaled.state ] && sudo tailscale status --json 2>/dev/null | jq -e '.Self.Online == true' >/dev/null 2>&1; then
  sudo mkdir -p /root
  sudo touch "$MARKER"
  log "node ownership marked ($MARKER) — IP will stay fixed across boots"
fi

if [ "$TS_API_TOKEN" != "NOT_SET" ] && [ -n "$TS_API_TOKEN" ]; then
  python3 "$SCRIPT_DIR/tailscale_cleanup.py" || log "stale-node cleanup skipped."
fi

if [ -n "$TS_FIXED_IP" ] && [ "$TS_FIXED_IP" != "NOT_SET" ] && [ "$TS_API_TOKEN" != "NOT_SET" ] && [ -n "$TS_API_TOKEN" ]; then
  if [ "$IP" != "$TS_FIXED_IP" ]; then
    log "IP ${IP} != desired ${TS_FIXED_IP}; trying to pin via API..."
    SELF_NODEKEY=$(sudo tailscale status --json 2>/dev/null | jq -r '.Self.PublicKey // .Self.NodeKey // empty' 2>/dev/null || true)
    SELF_ADDRS=$(sudo tailscale status --json 2>/dev/null | jq -r '[.Self.TailscaleIPs[]] | join(",")' 2>/dev/null || true)
    DEV_ID=""
    DEV_JSON=$(curl -sS --max-time 20 -H "Authorization: Bearer ${TS_API_TOKEN}" "https://api.github.com/../" 2>/dev/null || echo '{}')
    DEV_JSON=$(curl -sS --max-time 20 -H "Authorization: Bearer ${TS_API_TOKEN}" "https://api.tailscale.com/api/v2/tailnet/-/devices?fields=all" 2>/dev/null || echo '{}')
    if [ -n "$SELF_NODEKEY" ]; then
      DEV_ID=$(echo "$DEV_JSON" | jq -r --arg k "$SELF_NODEKEY" '.devices[] | select(.nodeKey == $k) | .id' 2>/dev/null | head -1)
    fi
    if [ -z "$DEV_ID" ] && [ -n "$SELF_ADDRS" ]; then
      DEV_ID=$(echo "$DEV_JSON" | jq -r --arg a "$SELF_ADDRS" '.devices[] | select((.addresses | join(",")) == $a) | .id' 2>/dev/null | head -1)
    fi
    if [ -n "$DEV_ID" ]; then
      RESP=$(curl -sS --max-time 20 -X POST -H "Authorization: Bearer ${TS_API_TOKEN}" -H "Content-Type: application/json" "https://api.tailscale.com/api/v2/device/${DEV_ID}/ip" -d "{\"ipv4\":\"${TS_FIXED_IP}\"}" -w '\nHTTP:%{http_code}' 2>/dev/null || true)
      log "pin API response: $(echo "$RESP" | tail -1)"
      sleep 5
      IP=$(sudo tailscale ip -4 2>/dev/null | head -1 || echo "$IP")
      log "IPv4 after pin attempt: ${IP}"
    else
      log "WARNING: could not map local node to API device for IP pinning"
    fi
  else
    log "IP already equals desired ${TS_FIXED_IP}"
  fi
else
  log "no fixed IP pinning (TAILSCALE_FIXED_IP or API token not set) — identity restore keeps IP"
fi

TS_IP="$IP"
log "FINAL IPv4 = ${TS_IP}"
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "TS_IP=${TS_IP}" >> "$GITHUB_ENV"
fi

if [ "$TS_API_TOKEN" != "NOT_SET" ] && [ -n "$TS_API_TOKEN" ]; then
  TS_SELF_NODEKEY=$(sudo tailscale status --json 2>/dev/null | jq -r '.Self.PublicKey // empty' 2>/dev/null || true)
  TS_AUTHKEY_ID=$(printf '%s' "$TS_AUTH_KEY" | cut -d'-' -f3 2>/dev/null || true)
  TAILSCALE_API_TOKEN="$TS_API_TOKEN" TS_SELF_NODEKEY="$TS_SELF_NODEKEY" TS_AUTHKEY_ID="$TS_AUTHKEY_ID" python3 "$SCRIPT_DIR/tailscale_expiry_check.py" 2>&1 || true
else
  log "no API token — key expiry check skipped"
fi

log "status:"
sudo tailscale status || true
