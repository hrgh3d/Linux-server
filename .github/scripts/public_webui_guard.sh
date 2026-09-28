#!/usr/bin/env bash
# Public web UI routing. Funnel has three HTTPS ports; OmniRoute and 9router
# are deliberately separated at the public listener as requested:
#   443   -> OmniRoute (root), Hermes Dashboard (/hermes-dashboard), CloudCLI (/cloudcli)
#   8443  -> 9router (root)
#   10000 -> Hermes Server Gateway
# Each application owns its internal authentication; Nginx adds no Basic Auth.
set -uo pipefail

SITE=/etc/nginx/sites-available/public-webui
ENABLED=/etc/nginx/sites-enabled/public-webui
PORTAL=/var/www/public-webui
LOG=/var/log/public-webui-guard.log
LEGACY_AUTH=/etc/nginx/.htpasswd-public-webui
say() { printf '[%s] %s\n' "$(date -u '+%F %T')" "$*" >>"$LOG"; }

command -v nginx >/dev/null 2>&1 || { say 'nginx absent — Funnel unchanged'; exit 0; }
command -v tailscale >/dev/null 2>&1 || { say 'tailscale absent — Funnel unchanged'; exit 0; }

TSIP=$(tailscale ip -4 2>/dev/null | head -1)
FQDN=$(tailscale status --json 2>/dev/null | python3 -c '
import json,sys
try: print(json.load(sys.stdin).get("Self",{}).get("DNSName", "").rstrip("."))
except Exception: pass' 2>/dev/null)
[ -n "$TSIP" ] && [ -n "$FQDN" ] || { say 'Tailscale identity unavailable — Funnel unchanged'; exit 0; }

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
<h1>ورود به پنل‌ها</h1><p>هر پنل احراز هویت داخلی خودش را دارد؛ Nginx رمز جداگانه‌ای ندارد.</p>
<a href="https://${FQDN}/">OmniRoute</a><a href="https://${FQDN}:8443/">9router</a><a href="https://${FQDN}/hermes-dashboard/">Hermes Dashboard</a>
<a href="https://${FQDN}/cloudcli/">CloudCLI</a><a href="https://${FQDN}:10000/">Hermes Server Gateway</a>
</html>
EOF

cat >"$SITE" <<'NGINX'
# Managed by /usr/local/bin/public_webui_guard.sh.
# No auth_basic: every published application owns its authentication.
server {
    listen 127.0.0.1:10443;
    server_name _;
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
        return 200 '<!doctype html><html lang="fa" dir="rtl"><meta charset="utf-8"><title>Hamid Web UI</title><style>body{max-width:700px;margin:3rem auto;padding:0 1rem;font:16px/1.8 system-ui;background:#10151f;color:#edf2f7}a{display:block;margin:12px 0;padding:14px;background:#1f2a3a;color:#9fe3ff;border-radius:10px;text-decoration:none}</style><h1>ورود به پنل‌ها</h1><p>هر پنل ورود داخلی خود را دارد.</p><a href="/">OmniRoute</a><a href="https://$host:8443/">9router</a><a href="/hermes-dashboard/">Hermes Dashboard</a><a href="/cloudcli/">CloudCLI</a><a href="https://$host:10000/">Hermes Server Gateway</a></html>';
    }

    location = /cloudcli { return 301 /cloudcli/; }
    location /cloudcli/ {
        proxy_set_header X-Forwarded-Prefix /cloudcli;
        proxy_set_header Accept-Encoding "";
        proxy_hide_header Cache-Control;
        add_header Cache-Control "no-store, max-age=0" always;
        proxy_pass http://127.0.0.1:3001/;
        proxy_redirect ~^https?://[^/]+(/.*)$ https://$host/cloudcli$1;
        proxy_redirect ~^/(.*)$ https://$host/cloudcli/$1;
        # CloudCLI is a root-built SPA. Rewrite its browser-visible resources
        # and API base to the dedicated /cloudcli prefix.
        sub_filter_once off;
        sub_filter_types text/css application/javascript application/json;
        sub_filter 'window.location.origin' 'window.location.origin+"/cloudcli"';
        sub_filter 'href="/' 'href="/cloudcli/';
        sub_filter 'src="/' 'src="/cloudcli/';
        sub_filter '"/assets/' '"/cloudcli/assets/';
        sub_filter "'/assets/" "'/cloudcli/assets/";
        sub_filter '`/assets/' '`/cloudcli/assets/';
        sub_filter '"/api/' '"/cloudcli/api/';
        sub_filter "'/api/" "'/cloudcli/api/";
        sub_filter '`/api/' '`/cloudcli/api/';
        sub_filter '"/icons/' '"/cloudcli/icons/';
        sub_filter "'/icons/" "'/cloudcli/icons/";
        sub_filter '`/icons/' '`/cloudcli/icons/';
        sub_filter '"/favicon.' '"/cloudcli/favicon.';
        sub_filter "'/favicon." "'/cloudcli/favicon.";
        sub_filter '`/favicon.' '`/cloudcli/favicon.';
        sub_filter '"/manifest.json' '"/cloudcli/manifest.json';
        sub_filter "'/manifest.json" "'/cloudcli/manifest.json";
        sub_filter '`/manifest.json' '`/cloudcli/manifest.json';
        sub_filter '"/sw.js' '"/cloudcli/sw.js';
        sub_filter "'/sw.js" "'/cloudcli/sw.js";
        sub_filter '`/sw.js' '`/cloudcli/sw.js';
    }

    location = /hermes-dashboard { return 301 /hermes-dashboard/; }
    location /hermes-dashboard/ {
        proxy_set_header X-Forwarded-Prefix /hermes-dashboard;
        proxy_set_header Accept-Encoding "";
        proxy_hide_header Cache-Control;
        add_header Cache-Control "no-store, max-age=0" always;
        proxy_pass http://127.0.0.1:9120/;
        proxy_redirect ~^https?://[^/]+(/.*)$ https://$host$1;
        proxy_redirect ~^(/.*)$ https://$host$1;
        sub_filter_once off;
        sub_filter_types text/css application/javascript application/json;
        sub_filter 'href="/' 'href="/hermes-dashboard/';
        sub_filter 'src="/' 'src="/hermes-dashboard/';
        sub_filter '"/auth/' '"/hermes-dashboard/auth/';
        sub_filter "'/auth/" "'/hermes-dashboard/auth/";
        sub_filter '`/auth/' '`/hermes-dashboard/auth/';
        sub_filter '"next":"/"' '"next":"/hermes-dashboard/"';
    }

    # OmniRoute owns the public root. No prefix or shared public route with
    # 9router exists here, so its /home, /api and /_next URLs stay OmniRoute.
    location / { proxy_pass http://127.0.0.1:20130; }
}

server {
    # 9router has its own public Funnel port and its own root namespace.
    listen 127.0.0.1:18443;
    server_name _;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    location / { proxy_pass http://127.0.0.1:9121; }
}

server {
    listen 127.0.0.1:11000;
    server_name _;
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
rm -f "$LEGACY_AUTH"
ln -sfn "$SITE" "$ENABLED"
nginx -t >/dev/null 2>&1 || { say 'nginx validation failed — Funnel unchanged'; exit 1; }
systemctl reload nginx >/dev/null 2>&1 || { say 'nginx reload failed — Funnel unchanged'; exit 1; }

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
