#!/usr/bin/env bash
# Public, application-authenticated web entrypoints for the retained dashboards.
# Funnel permits only 443, 8443 and 10000. Each exposed application owns its
# own login; Nginx is only the reverse-proxy/path-routing layer.
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

# Do not publish a stale/error page. App-level authentication responses are
# valid readiness responses because the application, not Nginx, owns login.
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
<h1>ورود به پنل‌ها</h1><p>هر پنل احراز هویت داخلی خودش را دارد؛ Nginx رمز جداگانه‌ای نمایش نمی‌دهد.</p>
<a href="/">9router</a><a href="/hermes-dashboard/">Hermes Dashboard</a><a href="/omniroute/">OmniRoute</a>
<a href="https://${FQDN}:8443/">CloudCLI</a><a href="https://${FQDN}:10000/">Hermes Server</a>
<small>برای اطلاعات ورود داخلی هر برنامه، فایل WEBUI-ACCESS.md را ببینید.</small>
</html>
EOF

cat >"$SITE" <<'NGINX'
# Managed by /usr/local/bin/public_webui_guard.sh.
# Do not add auth_basic here: every public app has its own authentication.
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
        return 200 '<!doctype html><html lang="fa" dir="rtl"><meta charset="utf-8"><title>Hamid Web UI</title><style>body{max-width:700px;margin:3rem auto;padding:0 1rem;font:16px/1.8 system-ui;background:#10151f;color:#edf2f7}a{display:block;margin:12px 0;padding:14px;background:#1f2a3a;color:#9fe3ff;border-radius:10px;text-decoration:none}</style><h1>ورود به پنل‌ها</h1><p>هر پنل رمز داخلی خود را دارد؛ Nginx رمز جداگانه‌ای ندارد.</p><a href="/">9router</a><a href="/hermes-dashboard/">Hermes Dashboard</a><a href="/omniroute/">OmniRoute</a><a href="https://$host:8443/">CloudCLI</a><a href="https://$host:10000/">Hermes Server</a></html>';
    }

    # 9router owns the public root, avoiding broken absolute static paths.
    location / { proxy_pass http://127.0.0.1:9121; }

    location = /hermes-dashboard { return 301 /hermes-dashboard/; }
    location /hermes-dashboard/ {
        proxy_set_header X-Forwarded-Prefix /hermes-dashboard;
        proxy_set_header Accept-Encoding "";
        # These responses are rewritten per public prefix; do not let an older
        # root-path JavaScript chunk remain immutable in a browser cache.
        proxy_hide_header Cache-Control;
        add_header Cache-Control "no-store, max-age=0" always;
        proxy_pass http://127.0.0.1:9120/;
        proxy_redirect ~^https?://[^/]+(/.*)$ https://$host$1;
        proxy_redirect ~^(/.*)$ https://$host$1;
        # Hermes' login page has an inline fetch('/auth/password-login').
        # Rewrite it and the post-login JSON target under the public prefix;
        # otherwise the browser posts to the 9router root and reports failure.
        sub_filter_once off;
        sub_filter_types text/html text/css application/javascript application/json;
        sub_filter 'href="/' 'href="/hermes-dashboard/';
        sub_filter 'src="/' 'src="/hermes-dashboard/';
        sub_filter '"/auth/' '"/hermes-dashboard/auth/';
        sub_filter "'/auth/" "'/hermes-dashboard/auth/";
        sub_filter '`/auth/' '`/hermes-dashboard/auth/';
        sub_filter '"next":"/"' '"next":"/hermes-dashboard/"';
    }

    location = /omniroute { return 301 /omniroute/; }
    location /omniroute/ {
        proxy_set_header X-Forwarded-Prefix /omniroute;
        proxy_set_header Accept-Encoding "";
        # Chunks are rewritten below, so serve the public representation fresh.
        proxy_hide_header Cache-Control;
        add_header Cache-Control "no-store, max-age=0" always;
        proxy_pass http://127.0.0.1:20130/;
        proxy_redirect ~^https?://[^/]+(/.*)$ https://$host$1;
        proxy_redirect ~^/(.*)$ https://$host/omniroute/$1;

        # OmniRoute is a Next.js SPA. Its initial HTML is easy to prefix, but
        # its chunks also emit root-relative /api, /_next and navigation URLs.
        # Without these rewrites a browser requests 9router at the public root
        # and remains on the OmniRoute loading screen.
        sub_filter_once off;
        # Login returns JSON containing its post-login route, so JSON must be
        # filtered too; otherwise its /home target leaves /omniroute/ and lands
        # on the 9router public root.
        sub_filter_types text/html text/css application/javascript application/json;
        sub_filter 'window.location.origin' 'window.location.origin+"/omniroute"';
        sub_filter 'href="/' 'href="/omniroute/';
        sub_filter 'src="/' 'src="/omniroute/';
        sub_filter '"/_next/' '"/omniroute/_next/';
        sub_filter "'/_next/" "'/omniroute/_next/";
        sub_filter '`/_next/' '`/omniroute/_next/';
        sub_filter '"/api/' '"/omniroute/api/';
        sub_filter "'/api/" "'/omniroute/api/";
        sub_filter '`/api/' '`/omniroute/api/';
        sub_filter '"/dashboard' '"/omniroute/dashboard';
        sub_filter "'/dashboard" "'/omniroute/dashboard";
        sub_filter '`/dashboard' '`/omniroute/dashboard';
        sub_filter '"/login' '"/omniroute/login';
        sub_filter "'/login" "'/omniroute/login";
        sub_filter '`/login' '`/omniroute/login';
        sub_filter '"/home' '"/omniroute/home';
        sub_filter "'/home" "'/omniroute/home";
        sub_filter '`/home' '`/omniroute/home';
        sub_filter '"/forgot-password' '"/omniroute/forgot-password';
        sub_filter "'/forgot-password" "'/omniroute/forgot-password";
        sub_filter '`/forgot-password' '`/omniroute/forgot-password';
        sub_filter '"/providers/' '"/omniroute/providers/';
        sub_filter "'/providers/" "'/omniroute/providers/";
        sub_filter '`/providers/' '`/omniroute/providers/';
        sub_filter '"/sw.js' '"/omniroute/sw.js';
        sub_filter "'/sw.js" "'/omniroute/sw.js";
        sub_filter '`/sw.js' '`/omniroute/sw.js';
    }
}

server {
    listen 127.0.0.1:18443;
    server_name _;
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

# The old public Nginx verifier is intentionally retired: authentication now
# happens inside every listed application.
rm -f "$LEGACY_AUTH"
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
