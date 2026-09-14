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
    # FIX (v6.16.1): ورکر nginx با www-data اجرا می‌شود — با root:root فایل
    # خوانده نمی‌شد و هر درخواست احرازاشده 500 می‌گرفت (Permission denied).
    if chown root:www-data "$HTPASSWD" 2>/dev/null; then chmod 640 "$HTPASSWD"; else chmod 644 "$HTPASSWD"; fi
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

# FIX (v6.16.1): نرمال‌سازی مالکیت htpasswd — حتی اگر فایل از state برگشته باشد
# (آرشیو می‌تواند root:root 640 داشته باشد) تا www-data همیشه بتواند بخواند.
if [ -f "$HTPASSWD" ]; then
  if ! chown root:www-data "$HTPASSWD" 2>/dev/null; then chmod 644 "$HTPASSWD"; else chmod 640 "$HTPASSWD"; fi
  log "htpasswd perms normalized ($(stat -c '%U:%G %a' "$HTPASSWD" 2>/dev/null))"
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
        # FIX (v6.16.2): بک‌اند hermes هدر Host را اعتبارسنجی می‌کند («Invalid Host
        # header») — host خودِ upstream پاس داده می‌شود تا هر آدرس تونل عمومی کار کند.
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
log "nginx site configured: :${DASH_PORT} (auth) -> :${BACK_PORT}"

# ---- v6.14: گارد داشبورد 9router (9121 auth -> 20128 loopback) -------------
# همان htpasswd (hamid + DASHBOARD_PASSWORD). تونل عمومی 9router فقط به 9121
# وصل می‌شود → داشبورد 9router هرگز بدون رمز عمومی نمی‌شود.
R_DASH_PORT=9121
R_BACK_PORT=20128
SITE_R=/etc/nginx/sites-available/9router-dash
cat > "$SITE_R" <<NGINX
# 9router dashboard behind Basic Auth (v6.14)
server {
    listen 127.0.0.1:${R_DASH_PORT};
    listen [::1]:${R_DASH_PORT};
    server_name _;

    auth_basic "9router Dashboard";
    auth_basic_user_file ${HTPASSWD};

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
log "nginx site configured: :${R_DASH_PORT} (auth) -> :${R_BACK_PORT} (9router)"

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
# v6.16.1: پروب WITH creds — قبلاً فقط 401 چک می‌شد و 500ِ پشت احراز هویت دیده نمی‌شد!
if [ -n "${DASHBOARD_PASSWORD:-}" ]; then
  CODE_AUTH=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 -u "${USER_NAME}:${DASHBOARD_PASSWORD}" "http://127.0.0.1:${DASH_PORT}/" 2>/dev/null || echo 000)
  log "GET / with creds -> HTTP ${CODE_AUTH} (200/30x = OK; 500 = htpasswd unreadable by nginx)"
  if [ "$CODE_AUTH" = "500" ]; then
    chmod 644 "$HTPASSWD" 2>/dev/null || true
    systemctl reload nginx >/dev/null 2>&1 || true
    sleep 1
    CODE_AUTH2=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 -u "${USER_NAME}:${DASHBOARD_PASSWORD}" "http://127.0.0.1:${DASH_PORT}/" 2>/dev/null || echo 000)
    log "auto-fix (chmod 644 + reload) -> HTTP ${CODE_AUTH2}"
  fi
fi
exit 0
