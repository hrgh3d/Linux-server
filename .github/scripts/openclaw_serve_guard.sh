#!/usr/bin/env bash
# openclaw_serve_guard.sh — v6.33
#
# چرا لازم است:
#   با gateway.tailscale.mode=serve، خودِ OpenClaw مسیر Tailscale Serve را
#   هنگام استارت claim می‌کند. اگر نشست LocalAPI تیل‌اسکیل بازنشانی شود
#   (ری‌استارت tailscaled، `tailscale up` دوباره، تعویض رانر)، آن claim از بین
#   می‌رود و OpenClaw خودش دوباره نمی‌گیردش. فقط این را لاگ می‌کند:
#     [tailscale] serve route claim exited; managed Tailscale ingress is
#     unavailable until the Gateway restarts
#   نتیجه‌ی خطرناک: سرویس «active» است و لوپ‌بک ۲۰۰ می‌دهد، ولی داشبورد HTTPS
#   و اپ موبایل کاملاً قطع‌اند و هیچ چک سلامتی متوجه نمی‌شود.
#
# ⚠️ درس v6.33 — `tailscale serve status` سیگنال معتبری نیست:
#   OpenClaw ingress را in-process نگه می‌دارد و در serve config روی دیسک
#   چیزی نمی‌نویسد. این دستور حتی وقتی داشبورد کاملاً سالم است «No serve
#   config» می‌گوید. استفاده از آن باعث ری‌استارت الکی سرویس سالم می‌شود.
#   سیگنال درست = همان چیزی که مرورگر کاربر می‌بیند: probe واقعی HTTPS.
set -u

PORT=18789
UNIT=openclaw-gateway.service
LOG=/var/log/openclaw-serve-guard.log
STAMP=/run/openclaw-serve-guard.last
COOLDOWN=180       # حداکثر یک ری‌استارت در هر ۳ دقیقه

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LOG"; }

[ -x /usr/local/bin/openclaw ] || exit 0
systemctl cat "$UNIT" >/dev/null 2>&1 || exit 0
systemctl is-enabled "$UNIT" >/dev/null 2>&1 || exit 0
systemctl is-active --quiet "$UNIT" || exit 0      # systemd خودش Restart= دارد
systemctl is-active --quiet tailscaled || exit 0   # بی‌فایده است

MODE=$(timeout 30 /usr/local/bin/openclaw config get gateway.tailscale.mode 2>/dev/null \
        | tr -d '"[:space:]')
[ "$MODE" = "serve" ] || [ "$MODE" = "funnel" ] || exit 0

DN=$(tailscale status --json 2>/dev/null | python3 -c "
import sys,json
try: print(json.load(sys.stdin).get('Self',{}).get('DNSName','').rstrip('.'))
except Exception: pass" 2>/dev/null)
[ -n "$DN" ] || exit 0

# ---- سیگنال ۱: همان چیزی که مرورگر می‌بیند ----
HTTPS=$(curl -s -m 12 -o /dev/null -w '%{http_code}' "https://$DN/" 2>/dev/null)
case "$HTTPS" in
  2*|3*|401|403) exit 0 ;;   # ingress برقرار است (حتی اگر auth بخواهد)
esac

# ---- سیگنال ۲: خود gateway زنده است؟ اگر نه، مشکل ingress نیست ----
LOOP=$(curl -s -m 8 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" 2>/dev/null)
case "$LOOP" in
  2*|3*|401|403) : ;;
  *) log "gateway itself not answering on loopback ($LOOP) — not an ingress problem, leaving to systemd"; exit 0 ;;
esac

# ---- سیگنال ۳ (تأیید): claim در لاگ از بین رفته ----
CLAIM=$(grep -E '\[tailscale\]' /var/log/openclaw-gateway.log 2>/dev/null | tail -1)

# ضد حلقه‌ی ری‌استارت
NOW=$(date +%s)
if [ -f "$STAMP" ]; then
  LAST=$(cat "$STAMP" 2>/dev/null || echo 0)
  case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
  [ $((NOW - LAST)) -lt "$COOLDOWN" ] && exit 0
fi
echo "$NOW" >"$STAMP" 2>/dev/null

log "INGRESS DOWN: https://$DN/ -> $HTTPS while loopback -> $LOOP"
log "  last tailscale log line: ${CLAIM:-none}"
systemctl restart "$UNIT"

for i in $(seq 1 25); do
  sleep 2
  H=$(curl -s -m 8 -o /dev/null -w '%{http_code}' "https://$DN/" 2>/dev/null)
  case "$H" in
    2*|3*|401|403) log "  RECOVERED after $((i*2))s (https -> $H)"; exit 0 ;;
  esac
done
log "  STILL DOWN after 50s — needs a human"
exit 1
