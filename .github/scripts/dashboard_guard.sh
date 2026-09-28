#!/bin/bash
# ============================================================================
# dashboard_guard.sh — reverse-proxy guard for Hermes Dashboard
#
# Chain: Cloudflare quick tunnel -> nginx :9119 -> dashboard :9120 (loopback)
# The Hermes application owns authentication. Nginx must not add Basic Auth,
# which would create a second, conflicting password prompt.
# ============================================================================
set -uo pipefail

DASH_PORT=9119
BACK_PORT=9120
SITE=/etc/nginx/sites-available/hermes-dash
MAP_CONF=/etc/nginx/conf.d/hermes-connection-map.conf
LEGACY_HTPASSWD=/etc/nginx/.htpasswd-hermes
log() { echo "[dash-guard $(date -u '+%T')] $*"; }

if ! command -v nginx >/dev/null 2>&1; then
  log "installing nginx..."
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -o DPkg::Lock::Timeout=120 nginx >/tmp/nginx-install.log 2>&1; then
    log "WARN: nginx install failed — dashboard proxy unavailable (see /tmp/nginx-install.log)"
    exit 0
  fi
  log "nginx installed"
fi

# WebSocket upgrade handling.
cat > "$MAP_CONF" <<'NGINX'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
NGINX

cat > "$SITE" <<NGINX
# Hermes dashboard — application login only; no nginx basic auth.
server {
    listen 127.0.0.1:${DASH_PORT};
    listen [::1]:${DASH_PORT};
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:${BACK_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        # The backend validates Host, so pass its own loopback host.
        proxy_set_header Host 127.0.0.1:${BACK_PORT};
        proxy_redirect http://127.0.0.1:${BACK_PORT}/ /;
        proxy_redirect http://localhost:${BACK_PORT}/ /;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
NGINX
ln -sf "$SITE" /etc/nginx/sites-enabled/hermes-dash
rm -f "$LEGACY_HTPASSWD"
log "nginx site configured: :${DASH_PORT} -> :${BACK_PORT} (Hermes app login only)"

# 9router already relies on its internal login only.
R_DASH_PORT=9121
R_BACK_PORT=20128
SITE_R=/etc/nginx/sites-available/9router-dash
cat > "$SITE_R" <<NGINX
# 9router dashboard — application login only; no nginx basic auth.
server {
    listen 127.0.0.1:${R_DASH_PORT};
    listen [::1]:${R_DASH_PORT};
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:${R_BACK_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
NGINX
ln -sf "$SITE_R" /etc/nginx/sites-enabled/9router-dash
log "nginx site configured: :${R_DASH_PORT} -> :${R_BACK_PORT} (9router app login only)"

# Patch an old service definition that may still bind the proxy port.
for U in /etc/systemd/system/hermes-dashboard.service /root/hermes-dashboard.service; do
  [ -f "$U" ] || continue
  if grep -q -- "--port ${DASH_PORT}" "$U"; then
    sed -i -- "s/--port ${DASH_PORT}/--port ${BACK_PORT}/" "$U"
    log "patched $U (port ${DASH_PORT} -> ${BACK_PORT})"
  else
    log "$U already not on port ${DASH_PORT}"
  fi
done
systemctl daemon-reload >/dev/null 2>&1 || true

systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx >/dev/null 2>&1 || systemctl start nginx >/dev/null 2>&1 || true
if systemctl is-active nginx >/dev/null 2>&1; then
  log "nginx active"
else
  log "WARNING: nginx not active — dashboard proxy unavailable"
fi

# A redirect to the Hermes application login is healthy and confirms that no
# extra Nginx password challenge is present.
CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:${DASH_PORT}/" 2>/dev/null || echo 000)
case "$CODE" in
  2*|3*) log "GET / without nginx credentials -> HTTP ${CODE} (application login owns auth)" ;;
  *) log "WARNING: dashboard proxy probe returned HTTP ${CODE}" ;;
esac
exit 0
