#!/usr/bin/env bash
# openclaw_serve_guard.sh — v6.32
#
# چرا لازم است:
#   OpenClaw وقتی gateway.tailscale.mode=serve باشد، مسیر Tailscale Serve را
#   هنگام بالا آمدن claim می‌کند. اگر tailscaled ری‌استارت شود، آن claim از بین
#   می‌رود و خود OpenClaw دوباره نمی‌گیردش؛ فقط این را لاگ می‌کند:
#     [tailscale] serve route claim exited; managed Tailscale ingress is
#     unavailable until the Gateway restarts
#   نتیجه: سرویس «active» است، لوپ‌بک ۲۰۰ می‌دهد، ولی داشبورد HTTPS و اپ
#   موبایل کاملاً قطع‌اند و هیچ‌کس خبردار نمی‌شود.
#
# این نگهبان هر دقیقه چک می‌کند و در صورت گم شدن ingress، gateway را
# ری‌استارت می‌کند تا claim دوباره گرفته شود.
#
# نصب: یک سرویس + تایمر ۶۰ ثانیه‌ای (توسط provision.sh نوشته می‌شود).
set -u

PORT=18789
UNIT=openclaw-gateway.service
LOG=/var/log/openclaw-serve-guard.log
STAMP=/run/openclaw-serve-guard.last

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LOG"; }

# اگر OpenClaw اصلاً نصب نیست، ساکت خارج شو (حالت Mode 2)
[ -x /usr/local/bin/openclaw ] || exit 0
systemctl cat "$UNIT" >/dev/null 2>&1 || exit 0

# اگر سرویس عمداً متوقف است، کاری نکن
systemctl is-enabled "$UNIT" >/dev/null 2>&1 || exit 0
if ! systemctl is-active --quiet "$UNIT"; then
  log "gateway not active — leaving it to systemd Restart="
  exit 0
fi

# tailscaled باید بالا باشد وگرنه ری‌استارت gateway بی‌فایده است
systemctl is-active --quiet tailscaled || { log "tailscaled down — skip"; exit 0; }

# مود serve فعال است؟
MODE=$(timeout 30 /usr/local/bin/openclaw config get gateway.tailscale.mode 2>/dev/null \
        | tr -d '"[:space:]')
[ "$MODE" = "serve" ] || [ "$MODE" = "funnel" ] || exit 0

# ---- تشخیص: آیا ingress واقعاً برقرار است؟ ----
SERVE=$(timeout 30 tailscale serve status 2>/dev/null)
if printf '%s' "$SERVE" | grep -q "$PORT"; then
  exit 0   # سالم
fi

# محافظت از حلقه‌ی ری‌استارت: حداکثر یک بار در هر ۳ دقیقه
NOW=$(date +%s)
if [ -f "$STAMP" ]; then
  LAST=$(cat "$STAMP" 2>/dev/null || echo 0)
  case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
  if [ $((NOW - LAST)) -lt 180 ]; then
    exit 0
  fi
fi
echo "$NOW" >"$STAMP" 2>/dev/null

log "ingress MISSING (tailscale serve has no :$PORT route) — restarting $UNIT"
log "  last gateway serve line: $(grep -E '\[tailscale\]' /var/log/openclaw-gateway.log 2>/dev/null | tail -1)"

systemctl restart "$UNIT"

# تأیید
for i in $(seq 1 20); do
  sleep 2
  if timeout 20 tailscale serve status 2>/dev/null | grep -q "$PORT"; then
    log "  RECOVERED after $((i*2))s — ingress re-claimed"
    exit 0
  fi
done
log "  STILL MISSING after 40s — needs a human"
exit 1
