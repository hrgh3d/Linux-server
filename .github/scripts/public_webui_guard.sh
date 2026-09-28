#!/usr/bin/env bash
# Public, password-protected web entrypoints for the retained dashboards.
# Funnel permits only 443, 8443 and 10000; nginx provides the auth boundary
# and a small portal before any public route is enabled.
set -uo pipefail

AUTH=/etc/nginx/.htpasswd-public-webui
SITE=/etc/nginx/sites-available/public-webui
ENABLED=/etc/nginx/sites-enabled/public-webui
PORTAL=/var/www/public-webui
LOG=/var/log/public-webui-guard.log
say() { printf '[%s] %s\n' "$(date -u '+%F %T')" "$*" >>"$LOG"; }

# Fail closed: the credential file is created once during the explicit deploy
# and persisted in the broad state. This guard never invents a public password.
[ -s "$AUTH" ] || { say 'public auth file absent — Funnel unchanged'; exit 0; }
command -v nginx >/dev/null 2>&1 || { say 'nginx absent — Funnel unchanged'; exit 0; }
command -v tailscale >/dev/null 2>&1 || { say 'tailscale absent — Funnel unchanged'; exit 0; }

TSIP=$(tailscale ip -4 2>/dev/null | head -1)
FQDN=$(tailscale status --json 2>/dev/null | python3 -c '
import json,sys
try: print(json.load(sys.stdin).get("Self",{}).get("DNSName", "").rstrip("."))
except Exception: pass' 2>/dev/null)
[ -n "$TSIP" ] && [ -n "$FQDN" ] || { say 'Tailscale identity unavailable — Funnel unchanged'; exit 0; }

# Do not publish a stale/error page. All retained backends must first answer
# locally; app-level authentication responses are intentionally accepted.
ready() {
  local url="$1" code
  code=$(curl -ksS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 8 "$url" 2>/dev/null || true)
  case "$code" in 2*|3*|401|403) return 0;; *) say "backend not ready: $url ($code)"; return 1;; esac
}
ready http://127.0.0.1:3001/ || exit 0
ready http://127.0.0.1:9121/ || exit 0
ready http://127.0.0.1:20130/ || exit 0
ready http://127.0.0.1:9120/ || exit 0
ready "http://${TSIP}:9122/api/status" || exit 0

mkdir -p "$PORTAL" /etc/nginx/sites-available /etc/nginx/sites-enabled
cat >"$PORTAL/index.html" <<EOF
<!doctype html><html lang="fa" dir="rtl"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Hamid Web UI</title>
<style>body{max-width:760px;margin:3rem auto;padding:0 1rem;font:16px/1.8 system-ui;background:#10151f;color:#edf2f7}a{display:block;margin:12px 0;padding:14px 16px;background:#1f2a3a;color:#9fe3ff;border-radius:10px;text-decoration:none}small{color:#aab7c7}</style>
<h1>ورود عمومی امن</h1><p>همهٔ مسیرها ابتدا با نام کاربری و رمز Nginx محافظت می‌شوند.</p>
<a href="/">9router</a><a href="/hermes-dashboard/">Hermes Dashboard</a><a href="/omniroute/">OmniRoute</a>
<a href="https://${FQDN}:8443/">CloudCLI</a><a href="https://${FQDN}:10000/">Hermes Serve</a>
<small>بعضی اپ‌ها ممکن است پس از دروازهٔ Nginx، ورود داخلی خودشان را نیز نمایش دهند.</small>
</html>
EOF

cat >"$SITE" <<'NGINX'
# Managed by /usr/local/bin/public_webui_guard.sh. Do not place credentials here.
# All public paths are protected by the separate 0600 htpasswd file.
server {
    listen 127.0.0.1:10443;
    server_name _;
    auth_basic "Hamid Public Web UI";
    auth_basic_user_file /etc/nginx/.htpasswd-public-webui;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";

    location = /portal { return 301 /portal/; }
    location = /portal/ {
        default_type text/html;
        return 200 '<!doctype html><html lang="fa" dir="rtl"><meta charset="utf-8"><title>Hamid Web UI</title><style>body{max-width:700px;margin:3rem auto;padding:0 1rem;font:16px/1.8 system-ui;background:#10151f;color:#edf2f7}a{display:block;margin:12px 0;padding:14px;background:#1f2a3a;color:#9fe3ff;border-radius:10px;text-decoration:none}</style><h1>ورود عمومی امن</h1><a href="/">9router</a><a href="/hermes-dashboard/">Hermes Dashboard</a><a href="/omniroute/">OmniRoute</a><a href="https://$host:8443/">CloudCLI</a><a href="https://$host:10000/">Hermes Serve</a></html>';
    }

    # 9router owns the public root, avoiding broken absolute static paths.
    location / { proxy_pass http://127.0.0.1:9121; }

    # These applications remain available under explicit paths. The proxy strips
    # the public prefix and rewrites common HTML links/redirects to that prefix.
    location = /hermes-dashboard { return 301 /hermes-dashboard/; }
    location /hermes-dashboard/ {
        proxy_set_header X-Forwarded-Prefix /hermes-dashboard;
        proxy_pass http://127.0.0.1:9120/;
        # Hermes already honors X-Forwarded-Prefix. Rewrite only the backend
        # scheme/port, never add the path prefix a second time.
        proxy_redirect ~^https?://[^/]+(/.*)$ https://$host$1;
        proxy_redirect ~^(/.*)$ https://$host$1;
        sub_filter_once off;
        sub_filter 'href="/' 'href="/hermes-dashboard/';
        sub_filter 'src="/' 'src="/hermes-dashboard/';
    }
    location = /omniroute { return 301 /omniroute/; }
    location /omniroute/ {
        proxy_set_header X-Forwarded-Prefix /omniroute;
        proxy_pass http://127.0.0.1:20130/;
        # OmniRoute does not always honor a forwarded prefix, so preserve it
        # when a relative redirect is returned.
        proxy_redirect ~^https?://[^/]+(/.*)$ https://$host$1;
        proxy_redirect ~^/(.*)$ https://$host/omniroute/$1;
        sub_filter_once off;
        sub_filter 'href="/' 'href="/omniroute/';
        sub_filter 'src="/' 'src="/omniroute/';
    }
}

server {
    listen 127.0.0.1:18443;
    server_name _;
    auth_basic "Hamid Public CloudCLI";
    auth_basic_user_file /etc/nginx/.htpasswd-public-webui;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    location / { proxy_pass http://127.0.0.1:3001; }
}

server {
    listen 127.0.0.1:11000;
    server_name _;
    auth_basic "Hamid Public Hermes";
    auth_basic_user_file /etc/nginx/.htpasswd-public-webui;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    location / { proxy_pass http://__HERMES_TSIP__:9122; }
}
NGINX
sed -i "s/__HERMES_TSIP__/${TSIP}/g" "$SITE"
# nginx workers must read the verifier but no non-web user may edit it.
chown root:www-data "$AUTH" 2>/dev/null || chown root:root "$AUTH"
chmod 640 "$AUTH"
ln -sfn "$SITE" "$ENABLED"
nginx -t >/dev/null 2>&1 || { say 'nginx validation failed — Funnel unchanged'; exit 1; }
systemctl reload nginx >/dev/null 2>&1 || { say 'nginx reload failed — Funnel unchanged'; exit 1; }

# Funnel exposes the same HTTPS endpoints to browsers outside the tailnet.
# --yes prevents a runner from hanging on an interactive confirmation.
for spec in '443 10443' '8443 18443' '10000 11000'; do
    set -- $spec
    if timeout 60 tailscale funnel --yes --bg --https="$1" "http://127.0.0.1:$2" >>"$LOG" 2>&1 \
       || timeout 60 tailscale funnel --bg --https="$1" "http://127.0.0.1:$2" >>"$LOG" 2>&1; then
        say "Funnel ensured :$1 -> 127.0.0.1:$2"
    else
        say "Funnel ensure failed :$1"
    fi
done
exit 0
