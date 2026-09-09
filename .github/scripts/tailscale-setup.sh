#!/bin/bash
# ============================================================================
# tailscale-setup.sh — اتصال خودکار و پایدار Tailscale (v6.0 شاخه AI)
#
# v6.0: پورت v5.2-v5.6 کپی اول منهای VPN (بدون Exit Node و بدون --ssh) +
#       هوک هشدار انقضا. استراتژی حفظ IP/هویت: reconnect با هویت ذخیره‌شده،
#       وگرنه ثبت تازه با auth key، سپس pin روی FIXED_IP، پاک‌سازی nodeهای مرده.
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

# هویت تیل‌اسکیل فقط در صورتی «خودی» است که marker ثبت شده باشد (بوت‌های بعدی
# بعد از Restore از state خودِ این سیستم). اگر state قدیمی/باقی‌ماندهٔ image بدون
# marker وجود داشته باشد (مثل اولین بوت یا residue رانر)، پاکش می‌کنیم تا این
# سیستم با auth key خودش به‌عنوان گره‌ی جدید ثبت شود و IP جدید بگیرد — بدون
# اینکه هویت/گره‌ی سیستم قبلی را بدزدد.
MARKER=/root/.ts-node-owned
OWNED=0
[ -f "$MARKER" ] && OWNED=1
if [ -s /var/lib/tailscale/tailscaled.state ] && [ "$OWNED" = 0 ]; then
  # v6.1 مهاجرت از v5.1 (که marker نداشت): اگر این بوت state را restore کرده
  # (marker رانِ قبلی موجود است)، این هویتِ legacy خودمان است — adopt کن نه wipe.
  if [ -f /root/persist-marker.txt ] && ! grep -q "run_id=${GITHUB_RUN_ID:-local}" /root/persist-marker.txt 2>/dev/null; then
    echo "[tailscale] legacy restored identity found (no marker yet) — adopting (v5.1 migration)..."
    sudo mkdir -p /root
    sudo touch "$MARKER"
    OWNED=1
  else
  echo "[tailscale] leftover/unowned identity found (no ownership marker) — wiping for fresh registration"
  # tailscaled ممکن است هنگام نصب auto-start شده باشد؛ اول باید متوقف شود وگرنه
  # state قدیمی قفل می‌ماند و up بعدی با 500 initMachineKeyLocked شکست می‌خورد.
  sudo systemctl stop tailscaled >/dev/null 2>&1 || sudo pkill -x tailscaled 2>/dev/null || true
  sleep 1
  sudo rm -rf /var/lib/tailscale
  # بازسازی دایرکتوری state: اگر parent دایرکتوری وجود نداشته باشد، tailscaled
  # نمی‌تواند فایل state را بنویسد و up با خطای زیر شکست می‌خورد (باگ v5.1 که
  # باعث «موفقیت توخالی» با IP=pending می‌شد):
  #   500 initMachineKeyLocked: ... tailscaled.state.tmp...: no such file or directory
  sudo mkdir -p /var/lib/tailscale
  sudo chmod 700 /var/lib/tailscale
  fi
fi

# همیشه پیش از (re)start دیمون از وجود دایرکتوری state مطمئن می‌شویم.
sudo mkdir -p /var/lib/tailscale

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

UP_FLAGS=(--hostname="${TS_HOSTNAME}" --accept-routes)

# همه‌ی فراخوانی‌های «tailscale up» با timeout سخت اجرا می‌شوند تا قدم هیچ‌وقت
# برای همیشه گیر نکند (up بدون auth در انتظار login تعاملی block می‌شود —
# همان هنگی که در v5.1 باعث Cancel دستی دو Run شد).
TS_UP_TIMEOUT=120
do_up() { # do_up <logfile> [extra up args...] -> rc of tailscale up (124 = timeout)
  local _log="$1"; shift
  timeout "$TS_UP_TIMEOUT" sudo tailscale up "${UP_FLAGS[@]}" "$@" >"$_log" 2>&1
  return $?
}
up_err() { # up_err <logfile> <rc> -> خلاصه‌ی یک‌خطی برای لاگ
  local _log="$1" _rc="$2" _note=""
  [ "$_rc" -eq 124 ] && _note="TIMED OUT after ${TS_UP_TIMEOUT}s; "
  echo "${_note}$(tail -3 "$_log" 2>/dev/null | tr '\n' ' ')"
}

# تصمیم‌گیری صرفاً بر اساس marker مالکیت (نه وجود فایل state): چون tailscaled
# بعد از start خودش یک state جدید می‌سازد، وجود فایل به‌معنای «هویت restored» نیست.
if [ -s /var/lib/tailscale/tailscaled.state ] && [ "$OWNED" = 1 ]; then
  # هویت خودِ این سیستم از state برگشته -> reconnect بدون Auth => همان IP
  echo "[tailscale] Our identity (marker) restored — reconnecting without a new auth..."
  if do_up /tmp/ts_up.log; then
    echo "[tailscale] reconnect OK (same node key)"
  else
    RC=$?
    echo "[tailscale] reconnect failed ($(up_err /tmp/ts_up.log "$RC")); authenticating with auth key."
    # v6.2: --reset چون state بازیابی‌شده ممکن است prefهای ناسازگار داشته باشد
    # (مثل ‎--ssh از v5.1) و tailscale بدون reset با خطای non-default flags رد می‌کند.
    if do_up /tmp/ts_up2.log --authkey="${TS_AUTH_KEY}" --reset; then
      echo "[tailscale] authenticated with auth key (identity not reusable — new registration)"
    else
      RC=$?
      echo "[tailscale] ERROR: tailscale up failed: $(up_err /tmp/ts_up2.log "$RC")"
    fi
  fi
else
  # بدون marker = اولین بوت / node جدید / residue پاک‌شده -> ثبت تازه با auth key
  echo "[tailscale] Fresh registration with TAILSCALE_AUTH_KEY..."
  if do_up /tmp/ts_up3.log --authkey="${TS_AUTH_KEY}"; then
    echo "[tailscale] authenticated OK (new node)"
  else
    RC=$?
    echo "[tailscale] WARNING: tailscale up failed (rc=${RC}): $(up_err /tmp/ts_up3.log "$RC")"
    # یک تلاش مجدد بعد از اطمینان از دایرکتوری state و restart دیمون
    # (پوشش race استارت tailscaled و خطاهای گذرای control-plane مثل 500)
    echo "[tailscale] retrying once after ensuring state dir + daemon restart..."
    sudo mkdir -p /var/lib/tailscale
    if command -v systemctl &>/dev/null && sudo systemctl list-unit-files tailscaled >/dev/null 2>&1; then
      sudo systemctl restart tailscaled >/dev/null 2>&1 || true
    else
      sudo pkill -x tailscaled >/dev/null 2>&1 || true
      sleep 1
      sudo nohup tailscaled --state=/var/lib/tailscale/tailscaled.state >/var/log/tailscaled.log 2>&1 &
    fi
    sleep 3
    if do_up /tmp/ts_up4.log --authkey="${TS_AUTH_KEY}"; then
      echo "[tailscale] authenticated OK on retry (new node)"
    else
      RC=$?
      echo "[tailscale] ERROR: tailscale up failed twice: $(up_err /tmp/ts_up4.log "$RC")"
    fi
  fi
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

# اگر با وجود auth key نتوانستیم آنلاین شویم، ادامه دادن بی‌فایده است: رانر
# GitHub ورودی عمومی ندارد و سرور بدون Tailscale از هیچ‌جا reachable نیست.
# به‌جای «موفقیت توخالی» با IP=pending سریع fail می‌کنیم تا اعلان خطا برسد
# و دقیقه‌های Actions برای سرورِ ازکارافتاده هدر نرود (v5.2: fail-fast).
if [ -z "$IP" ] || [ "$IP" = "pending" ]; then
  echo "[tailscale] ERROR: node did not come online (no Tailscale IPv4)."
  echo "[tailscale] diagnostics — daemon state:"
  sudo tailscale status 2>&1 | head -8 || true
  echo "[tailscale] diagnostics — last up output:"
  cat /tmp/ts_up*.log 2>/dev/null | tail -6 || true
  echo "[tailscale] hint: if the log says 'invalid key'/'expired', rotate TAILSCALE_AUTH_KEY (use a reusable, non-expiring key)."
  bash "$SCRIPT_DIR/notify.sh" --type server --stage tailscale-online \
    --error "Tailscale node did not come online (IPv4=pending). Last up: $(cat /tmp/ts_up*.log 2>/dev/null | tail -2 | tr '\n' ' ')" || true
  exit 1
fi

# ثبت مالکیت گره برای بوت‌های بعدی (بعد از این که state این سیستم ذخیره شد،
# بوت بعدی marker را دارد => reconnect بدون auth => همان IP ثابت)
if [ -s /var/lib/tailscale/tailscaled.state ] && \
   sudo tailscale status --json 2>/dev/null | jq -e '.Self.Online == true' >/dev/null 2>&1; then
  sudo mkdir -p /root
  sudo touch "$MARKER"
  echo "[tailscale] node ownership marked ($MARKER) — IP will stay fixed across boots"
fi

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

# ---- هشدار انقضای کلیدها (هر بوت یک‌بار؛ هرگز بوت را fail نمی‌کند) ----
if [ "$TS_API_TOKEN" != "NOT_SET" ] && [ -n "$TS_API_TOKEN" ]; then
  TS_SELF_NODEKEY=$(sudo tailscale status --json 2>/dev/null | jq -r '.Self.PublicKey // empty' 2>/dev/null || true)
  TS_AUTHKEY_ID=$(printf '%s' "$TS_AUTH_KEY" | cut -d'-' -f3 2>/dev/null || true)
  TAILSCALE_API_TOKEN="$TS_API_TOKEN" TS_SELF_NODEKEY="$TS_SELF_NODEKEY" TS_AUTHKEY_ID="$TS_AUTHKEY_ID" \
    python3 "$SCRIPT_DIR/tailscale_expiry_check.py" 2>&1 || true
else
  echo "[key-expiry] no API token — check skipped"
fi

echo "[tailscale] status:"
sudo tailscale status || true
