#!/bin/bash
# ============================================================================
# dashboard_guard.sh (v6.10) — محافظت با رمز (Basic Auth) از داشبورد Hermes
#
# زنجیره:  public -> Cloudflare quick tunnel -> nginx :9119 (Basic Auth)
#           -> dashboard :9120 (فقط loopback)
#
#  - یونیت داشبورد 9119->9120 patch می‌شود (idempotent، هر بوت).
#  - htpasswd از secret DASHBOARD_PASSWORD ساخته می‌شود (SHA-512 crypt؛
#    آرشیو state فقط hash یک‌طرفه را می‌بیند، نه رمز).
#  - اگر secret تنظیم نباشد ولی htpasswd قبلی (از state) موجود باشد، همان
#    حفظ می‌شود — داشبورد هرگز «باز» نمی‌ماند مگر اینکه هیچ‌کدام نباشد (WARN).
#  - Non-fatal: در صورت هر خطا بوت ادامه می‌یابد.
# ============================================================================
set -uo pipefail

DASH_PORT=9119      # در دسترس از طریق تونل (رفتار آدرس‌های قبلی حفظ می‌شود)
BACK_PORT=9120      # خود داشبورد (فقط loopback)
HTPASSWD=/etc/nginx/.htpasswd-hermes
SITE=/etc/nginx/sites-available/hermes-dash
MAP_CONF=/etc/nginx/conf.d/hermes-connection-map.conf
USER_NAME="hamid"
log() { echo "[dash-guard $(date -u '+%T')] $*"; }

# ---- 1) nginx ------------------------------------------------------------
if ! command -v nginx >/dev/null 2>&1; then
  log "installing nginx..."
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -o DPkg::Lock::Timeout=120 nginx >/tmp/nginx-install.log 2>&1; then
    log "WARN: nginx install failed — dashboard stays unguarded (see /tmp/nginx-install.log)"
    exit 0
  fi
  log "nginx installed"
fi

# ---- 2) htpasswd از secret -------------------------------------------------
# SHA-512 crypt ($6$) — فرمتی که nginx auth_basic مستقیم verify می‌کند.
# openssl در base image همیشه موجود است (وابستگی به ماژول deprecated
# crypt پایتون ندارد).
if [ -n "${DASHBOARD_PASSWORD:-}" ]; then
  _SALT=$(tr -dc './0-9A-Za-z' < /dev/urandom | head -c 16)
  HASH=$(openssl passwd -6 -salt "$_SALT" "$DASHBOARD_PASSWORD" 2>/dev/null)
  if [ -n "$HASH" ]; then
    echo "${USER_NAME}:${HASH}" > "$HTPASSWD"
    chown root:root "$HTPASSWD"
    chmod 640 "$HTPASSWD"
    log "htpasswd regenerated from DASHBOARD_PASSWORD secret"
  else
    log "WARN: hash generation failed — keeping existing htpasswd (if any)"
  fi
else
  if [ -f "$HTPASSWD" ]; then
    log "DASHBOARD_PASSWORD not set — keeping existing htpasswd from state"
  else
    log "WARNING: no DASHBOARD_PASSWORD secret and no htpasswd — dashboard will be OPEN"
  fi
fi

# ---- 3) conf: map برای WS + site با auth ------------------------------------
cat > "$MAP_CONF" <<'NGINX'
# hermes dashboard WS upgrade handling
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
NGINX

cat > "$SITE" <<NGINX
# Hermes dashboard behind Basic Auth (v6.10)
server {
    listen 127.0.0.1:${DASH_PORT};
    listen [::1]:${DASH_PORT};
    server_name _;

    auth_basic "Hermes Dashboard";
    auth_basic_user_file ${HTPASSWD};

    location / {
        proxy_pass http://127.0.0.1:${BACK_PORT};
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
ln -sf "$SITE" /etc/nginx/sites-enabled/hermes-dash
log "nginx site configured: :${DASH_PORT} (auth) -> :${BACK_PORT}"

# ---- 4) patch یونیت داشبورد 9119 -> 9120 (idempotent) ----------------------
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

# ---- 5) استارت nginx -------------------------------------------------------
systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx >/dev/null 2>&1 || systemctl start nginx >/dev/null 2>&1 || true
if systemctl is-active nginx >/dev/null 2>&1; then
  log "nginx active"
else
  log "WARNING: nginx not active — dashboard unguarded"
fi

# ---- 6) sanity: auth باید فعال باشد ----------------------------------------
CODE_NOAUTH=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:${DASH_PORT}/" 2>/dev/null || echo 000)
log "GET / without creds -> HTTP ${CODE_NOAUTH} (401/403 = auth active; 200 = NO AUTH — check!)"
exit 0
