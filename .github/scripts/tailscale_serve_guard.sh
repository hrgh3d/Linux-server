#!/usr/bin/env bash
# Keep Tailscale Serve routes for retained dashboards only.
# Retired components (OpenClaw, Pi/Pi Web, AI Hub) are deliberately absent.
set -u
LOG=/var/log/tailscale-serve-guard.log
log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LOG"; }
systemctl is-active --quiet tailscaled || exit 0
DN=$(tailscale status --json 2>/dev/null | python3 -c '
import sys,json
try: print(json.load(sys.stdin).get("Self",{}).get("DNSName","").rstrip("."))
except Exception: pass' 2>/dev/null)
[ -n "$DN" ] || exit 0
# CloudCLI uses the authenticated public facade after it has been deployed.
# On an earlier runner (or before first deployment), preserve the direct tailnet
# route so a missing facade cannot break the existing private UI.
CLOUDCLI_PORT=3001
[ -f /etc/nginx/sites-enabled/public-webui ] && CLOUDCLI_PORT=18443
# https_port|loopback_port|required_unit|label
SERVE_MAP="
8443|${CLOUDCLI_PORT}|cloudcli.service|CloudCLI
9443|9119||Hermes Dashboard
9444|9121||9Router
9447|20130|omniroute.service|OmniRoute
"
ensure_route() {
  local hp="$1" lp="$2" req="$3" label="$4" loop ext
  [ -z "$req" ] || systemctl is-active --quiet "$req" 2>/dev/null || return 0
  loop=$(curl -s -m 8 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$lp/" 2>/dev/null)
  case "$loop" in 2*|3*|401|403) ;; *) return 0;; esac
  ext=$(curl -s -m 12 -o /dev/null -w '%{http_code}' "https://$DN:$hp/" 2>/dev/null)
  case "$ext" in 2*|3*|401|403) return 0;; esac
  log "$label ingress down (https=$ext, loopback=$loop); restoring :$hp"
  timeout 60 tailscale serve --bg --https="$hp" "http://127.0.0.1:$lp" >>"$LOG" 2>&1 || true
}
printf '%s\n' "$SERVE_MAP" | while IFS='|' read -r hp lp req label; do
  [ -n "${hp:-}" ] || continue
  ensure_route "$hp" "$lp" "$req" "$label" || true
done
# A blank trailing map line must not make the oneshot unit fail.
exit 0
