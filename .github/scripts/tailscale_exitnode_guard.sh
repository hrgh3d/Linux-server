#!/usr/bin/env bash
# Keep this runner out of both exit-node roles:
# - it must not advertise itself as an exit node;
# - it must not use another tailnet node as its exit node.
# This is deliberately a preferences-only guard: it never restarts tailscaled.
set -uo pipefail
LOG=/var/log/tailscale-exitnode-guard.log
say() { printf '[%s] %s\n' "$(date -u '+%F %T')" "$*" >>"$LOG"; }

command -v tailscale >/dev/null 2>&1 || exit 0
systemctl is-active --quiet tailscaled 2>/dev/null || exit 0

# `tailscale set` updates only the supplied preferences. It is bounded and
# explicit so a future `tailscale up` or restored state cannot re-enable either
# exit-node mode by omission.
if ! timeout 20 tailscale set --advertise-exit-node=false --exit-node= >/dev/null 2>&1; then
  say 'ERROR: unable to apply exit-node=false preferences'
  exit 1
fi

if ! tailscale debug prefs 2>/dev/null | python3 -c '
import json,sys
try:
    p=json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
if p.get("RouteAll") is not False: raise SystemExit(2)
if p.get("ExitNodeID") or p.get("ExitNodeIP"): raise SystemExit(3)
for route in p.get("AdvertiseRoutes") or []:
    if str(route) in ("0.0.0.0/0", "::/0"): raise SystemExit(4)
' ; then
  say 'ERROR: exit-node preference verification failed'
  exit 1
fi

if ! tailscale status --json 2>/dev/null | python3 -c '
import json,sys
s=json.load(sys.stdin).get("Self", {})
if s.get("ExitNode") or s.get("ExitNodeOption"): raise SystemExit(1)
' ; then
  say 'ERROR: exit-node status verification failed'
  exit 1
fi
say 'verified: not advertising and not using an exit node'
