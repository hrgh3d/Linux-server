#!/usr/bin/env bash
# start-services.sh — استارت سرویس‌های ماندگار بعد از restore (v6.4 - gateway fix)
# v6.4: رفع مشکل hermes-gateway که بین ران‌ها fail می‌شد
#   - صبر بیشتر برای user@0.service و /run/user/0
#   - fallback اجرای مستقیم gateway اگر user service fail شد
#   - لاگ دقیق‌تر برای دیباگ
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail=0

start_system() {
  local u="$1"
  if [ ! -f "/etc/systemd/system/$u" ]; then
    echo "[services] $u: unit file absent — skip"
    return 0
  fi
  sudo systemctl daemon-reload >/dev/null 2>&1 || true
  sudo systemctl enable "$u" >/dev/null 2>&1 || true
  if sudo systemctl start "$u" >/dev/null 2>&1; then
    echo "[services] $u: started"
  else
    echo "[services] WARNING: $u failed to start (non-fatal, boot continues)"
    sudo systemctl status "$u" --no-pager -l 2>/dev/null | tail -10 || true
    fail=1
  fi
}

# --- Hermes: سرویس‌های سیستمی ---
start_system hermes-dashboard.service
start_system hermes-tunnel.service

# --- v6.14: استک تونل‌ها + نگهبان آدرس‌ها ---
# اگر اسکریپت‌ها/یونیت‌ها گم شده باشند (state خراب/تازه)، از کپی معتبر ریپو
# بازسازی می‌شوند؛ بعد 9router و تونل آن و tunnel-watch (اعلام‌کننده‌ی آدرس‌ها
# فقط از راه ربات گزارش) استارت می‌شوند. همه idempotent.
ensure_tunnel_stack() {
  local repo_dir; repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local s
  for s in tunnel-run.sh tunnel-watch.sh; do
    if [ ! -x "/usr/local/bin/$s" ] && [ -f "$repo_dir/$s" ]; then
      echo "[services] /usr/local/bin/$s missing — installing from repo copy"
      sudo cp "$repo_dir/$s" "/usr/local/bin/$s" && sudo chmod +x "/usr/local/bin/$s"
    fi
  done
  # v6.47: دروازهٔ گزارش همیشه از نسخهٔ ریپو تازه‌سازی می‌شود (نه فقط وقتی گم
  # شده) تا اگر منطق ارسال عوض شد، نسخهٔ کهنه روی سرور نماند. تمام گزارش‌ها
  # فقط از همین مسیر و فقط به ربات گزارش می‌روند.
  if [ -f "$repo_dir/report.sh" ]; then
    sudo cp -f "$repo_dir/report.sh" /usr/local/bin/report.sh
    sudo chmod +x /usr/local/bin/report.sh
    echo "[services] report gateway installed (single telegram destination)"
  fi
  # v6.15: drop-in «همیشه ری‌استارت» برای یونیت‌های حیاتی (nginx شاملش نیست
  # که Restart دارد؟ دارد: همه با drop-in یکدست always می‌شوند) — idempotent.
  local _u _d _f
  for _u in nginx hermes-dashboard hermes-tunnel 9router 9router-tunnel; do
    _d="/etc/systemd/system/${_u}.service.d"; _f="${_d}/10-restart-always.conf"
    if [ ! -f "$_f" ]; then
      sudo mkdir -p "$_d"
      printf '[Service]\nRestart=always\nRestartSec=5\n' | sudo tee "$_f" >/dev/null
      sudo systemctl daemon-reload
      echo "[services] drop-in Restart=always for ${_u}"
    fi
  done
  # v6.15: رَپر «hermes dashboard» بدون ارور — پورت پیش‌فرض 9119 دست nginx
  # (گیت رمز داشبورد) است و بک‌اند واقعی روی 9120 به‌عنوان سرویس اجرا می‌شود؛
  # پس اگر سرویس زنده بود، به‌جای BACKEND_PORT_IN_USE آدرس‌ها چاپ می‌شود.
  # alias فقط در پوسته تعاملی است → سرویس‌ها/اسکریپت‌ها باینری واقعی را صدا می‌زنند.
  if [ ! -x /usr/local/bin/hermes-ui ]; then
    sudo tee /usr/local/bin/hermes-ui >/dev/null <<'SHIM'
#!/bin/bash
# hermes-ui — رپر دوستانه‌ی CLI (v6.15). هر چیزی جز «dashboard بدون --port
# وقتی 9119 اشغال است» عیناً به باینری واقعی پاس داده می‌شود.
if [ "${1:-}" = "dashboard" ]; then
  _hp=0; for _a in "$@"; do case "$_a" in --port|--port=*) _hp=1;; esac; done
  if [ "$_hp" = 0 ] && ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE ':9119$'; then
    echo "✅ Hermes Dashboard همین حالا به‌عنوان سرویس در حال اجراست (hermes-dashboard.service)."
    echo
    echo "آدرس روی سرور : http://localhost:9119"
    echo "ورود            : کاربر hamid + رمز داشبورد (secret DASHBOARD_PASSWORD)"
    _pub=$(head -1 /root/.hermes/tunnel_url.txt 2>/dev/null || true)
    if [ -n "${_pub:-}" ]; then
      echo "آدرس عمومی      : ${_pub}"
      echo "(تغییر آدرس عمومی را ربات گزارش با قالب «Hermes Dashboard : <آدرس>» اعلام می‌کند)"
    fi
    echo
    echo "وضعیت سرویس     : systemctl status hermes-dashboard --no-pager"
    echo "نمونه‌ی دوم روی پورت آزاد: hermes dashboard --port 0"
    exit 0
  fi
fi
exec /usr/local/bin/hermes "$@"
SHIM
    sudo chmod +x /usr/local/bin/hermes-ui
    echo "[services] installed /usr/local/bin/hermes-ui"
  fi
  local _rc
  for _rc in /root/.bashrc /home/Hamid/.bashrc; do
    if [ -f "$_rc" ] && ! sudo grep -q "alias hermes=" "$_rc" 2>/dev/null; then
      echo "alias hermes='/usr/local/bin/hermes-ui'" | sudo tee -a "$_rc" >/dev/null
      echo "[services] alias hermes added to $_rc"
    fi
  done
  if [ ! -f /etc/systemd/system/hermes-tunnel.service ] || \
     grep -q "hermes-tunnel.sh" /etc/systemd/system/hermes-tunnel.service 2>/dev/null; then
    echo "[services] (re)writing hermes-tunnel.service (generic tunnel-run.sh)"
    sudo tee /etc/systemd/system/hermes-tunnel.service >/dev/null <<'UNIT'
[Unit]
Description=Hermes dashboard cloudflared quick tunnel (via tunnel-run.sh)
After=hermes-dashboard.service network-online.target
Wants=hermes-dashboard.service

[Service]
Type=simple
ExecStart=/usr/local/bin/tunnel-run.sh hermes http://127.0.0.1:9119 /root/.hermes/tunnel_url.txt
Restart=always
RestartSec=20

[Install]
WantedBy=multi-user.target
UNIT
  fi
  if [ ! -f /etc/systemd/system/9router-tunnel.service ]; then
    sudo tee /etc/systemd/system/9router-tunnel.service >/dev/null <<'UNIT'
[Unit]
Description=9router dashboard cloudflared quick tunnel (guarded nginx :9121)
After=9router.service nginx.service network-online.target
Wants=9router.service

[Service]
Type=simple
ExecStart=/usr/local/bin/tunnel-run.sh 9router http://127.0.0.1:9121 /root/.9router/tunnel_url.txt
Restart=always
RestartSec=20

[Install]
WantedBy=multi-user.target
UNIT
  fi
  if [ ! -f /etc/systemd/system/tunnel-watch.service ]; then
    sudo tee /etc/systemd/system/tunnel-watch.service >/dev/null <<'UNIT'
[Unit]
Description=Dashboard tunnel address watcher (announces changes via report bot)
After=hermes-tunnel.service 9router-tunnel.service network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/tunnel-watch.sh
Restart=always
RestartSec=15

[Install]
WantedBy=multi-user.target
UNIT
  fi
  if [ ! -f /etc/systemd/system/9router.service ] && [ -x /usr/local/bin/9router ]; then
    sudo tee /etc/systemd/system/9router.service >/dev/null <<'UNIT'
[Unit]
Description=9Router AI router (dashboard port 20128)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=/root
ExecStart=/usr/local/bin/9router --no-browser --skip-update --log
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
  fi
  sudo systemctl daemon-reload >/dev/null 2>&1 || true
  for u in hermes-tunnel 9router-tunnel tunnel-watch 9router; do
    sudo systemctl enable "$u.service" >/dev/null 2>&1 || true
  done
}
ensure_tunnel_stack
start_system 9router.service
start_system 9router-tunnel.service
start_system tunnel-watch.service
# v6.26: OpenClaw Gateway — فقط اگر provision.sh یونیت را ساخته باشد
if [ -f /etc/systemd/system/openclaw-gateway.service ]; then
  start_system openclaw-gateway.service
fi

# --- v6.38: Headroom — پروکسی فشرده‌سازی کانتکست برای «Token Saver» پنل 9router
# پنل 9router خودش این پروسه را اجرا نمی‌کند («Headroom proxies must be started
# outside 9Router») و فقط به http://127.0.0.1:8787 وصل می‌شود. پس اینجا بالا
# می‌آید. venv در /opt/headroom و یونیت در /etc/systemd/system هر دو در
# persist.list هستند، ولی اگر venv به هر دلیلی گم شود خودش را بازمی‌سازد تا
# «Token Saver» بعد از چرخش رانر خاموش نماند.
ensure_headroom() {
  [ -f /etc/systemd/system/headroom.service ] || return 0
  if [ ! -x /opt/headroom/bin/headroom ]; then
    echo "[services] headroom: venv missing after restore — rebuilding..."
    python3 -m venv /opt/headroom >/dev/null 2>&1 || {
      sudo apt-get install -y -q python3-venv >/dev/null 2>&1
      python3 -m venv /opt/headroom >/dev/null 2>&1; }
    timeout 900 /opt/headroom/bin/pip install -q "headroom-ai[proxy]" \
      >/tmp/headroom-rebuild.log 2>&1 \
      && echo "[services] headroom: venv rebuilt" \
      || echo "[services] WARNING: headroom venv rebuild failed (see /tmp/headroom-rebuild.log)"
  fi
  mkdir -p /root/.headroom 2>/dev/null || true
}
ensure_headroom
if [ -f /etc/systemd/system/headroom.service ]; then
  start_system headroom.service
  # آماده‌باش کوتاه: پنل تا وقتی /health جواب ندهد دکمه را فعال نمی‌کند
  for _i in 1 2 3; do
    curl -fsS -m 3 http://127.0.0.1:8787/health >/dev/null 2>&1 && break
    sleep 3
  done
  if curl -fsS -m 3 http://127.0.0.1:8787/health >/dev/null 2>&1; then
    echo "[services] headroom: proxy healthy on 127.0.0.1:8787 (9router Token Saver ready)"
  else
    echo "[services] headroom: not answering yet — Restart=always will keep retrying"
  fi
fi

# --- CloudCLI UI (Claude Code web interface) — v6.43 -----------------------
# رابط وب Claude Code روی 3001. سه چیز باید بعد از هر چرخش برگردد:
#   ۱) یونیت systemd  ۲) فایل env زیر /etc  ۳) مسیر Tailscale Serve روی 8443
# پورت 443 مال OpenClaw است، پس CloudCLI روی 8443 می‌نشیند.
ensure_cloudcli() {
  command -v cloudcli >/dev/null 2>&1 || return 0
  if [ ! -f /etc/systemd/system/cloudcli.service ]; then
    echo "[services] cloudcli: unit missing — writing it"
    sudo tee /etc/systemd/system/cloudcli.service >/dev/null <<'UNIT'
[Unit]
Description=CloudCLI UI (Claude Code web interface)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
EnvironmentFile=/etc/cloudcli.env
ExecStart=/usr/local/bin/cloudcli start
Restart=always
RestartSec=5
KillMode=mixed
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
UNIT
    sudo systemctl daemon-reload
  fi
  mkdir -p /root/.cloudcli 2>/dev/null || true
}
# v6.45: کامبوهای 9router را به فهرست مدل‌های CloudCLI برمی‌گرداند.
# CloudCLI فهرست مدل‌های Claude را از یک کاتالوگ hardcode شده می‌خواند و فقط
# ردیف‌های جدول provider_models را به آن merge می‌کند. آن جدول در
# /root/.cloudcli/auth.db است که آرشیو می‌شود، پس معمولاً سالم برمی‌گردد —
# ولی اگر دیتابیس تازه ساخته شود (بازیابی ناقص یا نصب تمیز) کامبوها گم
# می‌شوند و کاربر دوباره فقط Sonnet/Opus می‌بیند. این تابع idempotent است:
# فقط کامبوی غایب را اضافه می‌کند.
# v6.47: کامبوها دیگر لیست ثابت نیستند — مستقیم از دیتابیس 9router خوانده
# می‌شوند. پس هر کامبویی که کاربر در پنل بسازد یا تغییر دهد، بعد از بوت بعدی
# خودکار در همهٔ برنامه‌ها ظاهر می‌شود و نیازی به ویرایش این اسکریپت نیست.
# طبق درخواست کاربر (v6.47) «تمام کامبوها در تمام برنامه‌ها» — شامل ultimate،
# چون خودش بعداً مدل داخلش را عوض می‌کند. Image هم می‌آید چون کاربر «تمام» گفت.
read_9router_combos() {
  python3 - <<'PYLIST'
import sqlite3
try:
    c = sqlite3.connect('/root/.9router/db/data.sqlite', timeout=10)
    for (n,) in c.execute("select name from combos order by name"):
        if n: print(n)
except Exception:
    pass
PYLIST
}

ensure_cloudcli_combos() {
  local db=/root/.cloudcli/auth.db
  [ -s "$db" ] || return 0
  local names; names="$(read_9router_combos | paste -sd, -)"
  [ -n "$names" ] || { echo "[services] cloudcli combos: no combos found in 9router"; return 0; }
  python3 - "$db" "$names" <<'PYCOMBO'
import sqlite3, sys
db, names = sys.argv[1], [x for x in sys.argv[2].split(",") if x]
try:
    c = sqlite3.connect(db, timeout=10)
    have = {r[0] for r in c.execute(
        "select model_id from provider_models where provider='claude'")}
    order = len(have)
    added = []
    for name in names:
        if name in have:
            continue
        c.execute(
            "insert into provider_models(provider,model_id,model_name,sort_order,"
            "created_at,updated_at) values('claude',?,?,?,datetime('now'),datetime('now'))",
            (name, "9router " + name, order))
        order += 1
        added.append(name)
    c.commit()
    print("[services] cloudcli combos: " + (", ".join(added) + " added" if added else "already present"))
except Exception as exc:
    print("[services] cloudcli combos: skipped (%s)" % exc)
PYCOMBO
}

# --- همان کامبوها برای Pi ---------------------------------------------------
ensure_pi_combos() {
  local mj=/root/.pi/agent/models.json
  [ -s "$mj" ] || return 0
  local names; names="$(read_9router_combos | paste -sd, -)"
  [ -n "$names" ] || return 0
  python3 - "$mj" "$names" <<'PYPI'
import json, sys
mj, names = sys.argv[1], [x for x in sys.argv[2].split(",") if x]
try:
    d = json.load(open(mj))
    prov = d.setdefault("providers", {}).setdefault("ninerouter", {})
    cur = {m.get("id") for m in prov.get("models", [])}
    add = [n for n in names if n not in cur]
    if add:
        prov.setdefault("models", []).extend(
            {"id": n, "contextWindow": 128000} for n in add)
        json.dump(d, open(mj, "w"), indent=2)
        print("[services] pi combos: %s added" % ", ".join(add))
    else:
        print("[services] pi combos: already present")
except Exception as exc:
    print("[services] pi combos: skipped (%s)" % exc)
PYPI
}

# --- همان کامبوها برای OpenClaw --------------------------------------------
ensure_openclaw_combos() {
  local cfg=/root/.openclaw/openclaw.json
  [ -s "$cfg" ] || return 0
  local names; names="$(read_9router_combos | paste -sd, -)"
  [ -n "$names" ] || return 0
  python3 - "$cfg" "$names" <<'PYOC'
import json, sys
cfg, names = sys.argv[1], [x for x in sys.argv[2].split(",") if x]
try:
    d = json.load(open(cfg))
    prov = d.setdefault("models", {}).setdefault("providers", {}).setdefault("ninerouter", {})
    models = prov.setdefault("models", [])
    cur = {m.get("id") if isinstance(m, dict) else m for m in models}
    add = [n for n in names if n not in cur]
    if add:
        models.extend({"id": n, "name": "9router " + n, "contextWindow": 128000}
                      for n in add)
        json.dump(d, open(cfg, "w"), indent=2)
        print("[services] openclaw combos: %s added" % ", ".join(add))
    else:
        print("[services] openclaw combos: already present")
except Exception as exc:
    print("[services] openclaw combos: skipped (%s)" % exc)
PYOC
}

ensure_pi_combos
ensure_openclaw_combos

# --- v6.47: Pi Web — رابط وب برای Pi -----------------------------------------
# خود Pi هیچ web UI داخلی ندارد (در pi --help هیچ فعل serve/web نیست).
# @agegr/pi-web بالغ‌ترین گزینهٔ موجود است: همان فایل‌های نشست Pi در
# ~/.pi/agent/sessions را می‌خواند (پس ترمینال و مرورگر دو نمای یک حالت‌اند)،
# و مهم‌تر: PI_WEB_PASSWORD، PI_WEB_HOSTNAME و PI_WEB_ALLOWED_HOSTS دارد که
# برای اجرای پشت Tailscale لازم است.
ensure_piweb() {
  command -v pi >/dev/null 2>&1 || return 0

  if [ ! -x /usr/local/bin/pi-web ]; then
    echo "[services] installing @agegr/pi-web"
    timeout 900 sudo npm install -g --no-fund --no-audit @agegr/pi-web@latest \
      >/tmp/piweb-install.log 2>&1 \
      || { echo "[services] pi-web install failed: $(tail -3 /tmp/piweb-install.log | tr '\n' ' ')"; return 0; }
  fi
  [ -x /usr/local/bin/pi-web ] || return 0

  # درس v6.34/v6.43: نام میزبان Tailscale باید در allowed hosts باشد وگرنه
  # Next.js درخواست پروکسی‌شده را رد می‌کند و کاربر صفحهٔ خطا می‌بیند.
  local DN
  DN=$(tailscale status --json 2>/dev/null | python3 -c "
import sys,json
try: print(json.load(sys.stdin).get('Self',{}).get('DNSName','').rstrip('.'))
except Exception: pass" 2>/dev/null)
  local PW="${DASHBOARD_PASSWORD:-hamidgh69}"

  sudo tee /etc/pi-web.env >/dev/null <<ENVF
PORT=30141
PI_WEB_HOSTNAME=127.0.0.1
PI_WEB_NO_OPEN=1
PI_WEB_SKIP_VERSION_CHECK=1
PI_WEB_PASSWORD=${PW}
PI_WEB_ALLOWED_HOSTS=${DN},${DN}:9445,127.0.0.1,localhost
PI_WEB_IDLE_TIMEOUT_MS=0
PI_CODING_AGENT_DIR=/root/.pi/agent
HOME=/root
ENVF
  sudo chmod 600 /etc/pi-web.env

  if [ ! -f /etc/systemd/system/pi-web.service ]; then
    sudo tee /etc/systemd/system/pi-web.service >/dev/null <<'UNIT'
[Unit]
Description=Pi Web — browser UI for the Pi coding agent
After=network-online.target 9router.service
Wants=network-online.target

[Service]
Type=simple
User=root
EnvironmentFile=/etc/pi-web.env
ExecStart=/usr/local/bin/pi-web
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
    sudo systemctl daemon-reload
  fi

  start_system pi-web.service
  local _i
  for _i in $(seq 1 12); do
    curl -fsS -m 3 -o /dev/null http://127.0.0.1:30141/ 2>/dev/null && break
    sleep 5
  done
  echo "[services] pi-web local: $(curl -s -o /dev/null -w '%{http_code}' -m 5 http://127.0.0.1:30141/)"
}
ensure_piweb


# ---------------------------------------------------------------- AI Hub
# پنل یکپارچهٔ مدیریت همهٔ برنامه‌های AI روی پورت 9446.
# درس v6.x: start-services.sh یونیت‌ها را خودکار کشف نمی‌کند، پس هر سرویس
# جدید باید صراحتاً اینجا اضافه شود وگرنه بعد از چرخش رانر برنمی‌گردد.
ensure_aihub() {
  local SRC="$SCRIPT_DIR/../../aihub"
  [ -d "$SRC/app" ] || { echo "[services] aihub source missing, skip"; return 0; }

  sudo mkdir -p /opt/aihub
  sudo cp -r "$SRC/app" "$SRC/static" "$SRC/requirements.txt" /opt/aihub/ 2>/dev/null || true

  if [ ! -x /opt/aihub/venv/bin/python ]; then
    echo "[services] creating aihub venv"
    sudo python3 -m venv /opt/aihub/venv >/tmp/aihub-venv.log 2>&1 || {
      echo "[services] aihub venv failed"; return 0; }
  fi
  # نصب فقط وقتی fastapi غایب است تا هر بوت چند دقیقه تلف نشود
  if ! /opt/aihub/venv/bin/python -c "import fastapi" >/dev/null 2>&1; then
    echo "[services] installing aihub deps"
    sudo /opt/aihub/venv/bin/pip -q install -r /opt/aihub/requirements.txt \
      >/tmp/aihub-pip.log 2>&1 || {
      echo "[services] aihub pip failed: $(tail -2 /tmp/aihub-pip.log | tr '\n' ' ')"; return 0; }
  fi

  sudo tee /etc/systemd/system/aihub.service >/dev/null <<'AIHUBUNIT'
[Unit]
Description=AI Hub - unified control panel for all AI programs
After=network-online.target 9router.service
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/aihub
EnvironmentFile=-/etc/profile.d/ai-clients.sh
Environment=PYTHONUNBUFFERED=1
Environment=XDG_RUNTIME_DIR=/run/user/0
ExecStart=/opt/aihub/venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 9446 --no-access-log
Restart=always
RestartSec=5
KillMode=mixed
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
AIHUBUNIT

  sudo systemctl daemon-reload
  sudo systemctl enable aihub.service >/dev/null 2>&1 || true
  sudo systemctl restart aihub.service || true
  local i
  for i in $(seq 1 10); do
    curl -fsS -m 3 -o /dev/null http://127.0.0.1:9446/api/health 2>/dev/null && break
    sleep 2
  done
  echo "[services] aihub: $(curl -s -o /dev/null -w '%{http_code}' -m 5 http://127.0.0.1:9446/api/health)"
}
ensure_aihub


ensure_cloudcli
# v6.44: وصله‌های سمت مرورگر (فونت گوگل + service worker) هر بوت دوباره اعمال
# می‌شوند، چون dist زیر node_modules است و با هر بازنصب npm تازه می‌شود.
if [ -f "$SCRIPT_DIR/cloudcli_patch.sh" ] && command -v cloudcli >/dev/null 2>&1; then
  sudo install -m 0755 "$SCRIPT_DIR/cloudcli_patch.sh" /usr/local/bin/cloudcli_patch.sh
  sudo /usr/local/bin/cloudcli_patch.sh || true
fi
if [ -f /etc/systemd/system/cloudcli.service ] && [ -s /etc/cloudcli.env ]; then
  start_system cloudcli.service
  # CloudCLI کند بالا می‌آید (اسکن نشست‌ها + ساخت ایندکس). ۱۵ ثانیه کم بود.
  for _i in $(seq 1 12); do
    curl -fsS -m 3 -o /dev/null http://127.0.0.1:3001/ 2>/dev/null && break
    sleep 5
  done
  # مسیر Serve روی 8443 بعد از چرخش/ری‌استارت tailscaled از بین می‌رود
  if ! tailscale serve status 2>/dev/null | grep -q '127.0.0.1:3001'; then
    tailscale serve --bg --https=8443 http://127.0.0.1:3001 >/dev/null 2>&1 \
      && echo "[services] cloudcli: tailscale serve 8443 re-established" \
      || echo "[services] cloudcli: WARNING tailscale serve 8443 failed"
  fi
  if curl -fsS -m 3 -o /dev/null http://127.0.0.1:3001/ 2>/dev/null; then
    echo "[services] cloudcli: UI healthy on 127.0.0.1:3001 (https :8443 via tailnet)"
    ensure_cloudcli_combos
  else
    echo "[services] cloudcli: not answering yet — Restart=always will keep retrying"
  fi
fi

# --- Hermes gateway: یونیت user روت ---
# v6.11: اگر یونیت گم شده باشد (خرابی state)، همین‌جا بازسازی‌اش کن —
# بوت‌های بعدی از راه استاندارد (همین یونیت) بالا می‌آیند.
GW_UNIT=/root/.config/systemd/user/hermes-gateway.service
# v6.12: اگر snapshot فاسد کل هرمز را برده باشد ولی توکن تزریق‌شده موجود باشد،
# با همان نصب‌کننده‌ی استانداردِ پروویژن باز نصب کن (یک‌بار؛ بعد در state می‌ماند).
VENV_PY=/usr/local/lib/hermes-agent/venv/bin/python
if [ ! -x "$VENV_PY" ] && grep -q '^TELEGRAM_BOT_TOKEN=.\{4,\}' /root/.hermes/.env 2>/dev/null; then
  echo "[services] hermes venv missing but token present — recovery install (standard installer)"
  if curl -fsSL --max-time 60 https://hermes-agent.nousresearch.com/install.sh -o /tmp/hermes-install.sh; then
    timeout 540 sudo env HERMES_HOME=/root/.hermes bash /tmp/hermes-install.sh --non-interactive --skip-browser --skip-computer-use >/tmp/hermes-reinstall.log 2>&1 \
      && echo "[services] hermes recovery install OK" \
      || { echo "[services] WARNING: hermes recovery install failed (rc=$?)"; tail -12 /tmp/hermes-reinstall.log 2>/dev/null; }
  else
    echo "[services] WARNING: could not download hermes installer"
  fi
fi
# v6.11b: دایرکتوری لاگ هر بوت تضمین شود — بدون آن خود gateway موقع نوشتن
# لاگ کرش می‌کند (دقیقاً همان‌طور که در بازسازی دستی دیدیم).
sudo mkdir -p /root/.hermes/logs 2>/dev/null || mkdir -p /root/.hermes/logs
sudo chown -R root:root /root/.hermes 2>/dev/null || true
if [ ! -f "$GW_UNIT" ] && [ -x /usr/local/lib/hermes-agent/venv/bin/python ]; then
  echo "[services] hermes-gateway unit missing — recreating standard unit"
  sudo mkdir -p /root/.config/systemd/user
  sudo tee "$GW_UNIT" >/dev/null <<'UNIT'
[Unit]
Description=Hermes Telegram Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HERMES_HOME=/root/.hermes
ExecStart=/usr/local/lib/hermes-agent/venv/bin/python -m hermes_cli.main gateway run
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
UNIT
fi
if [ -f /root/.config/systemd/user/hermes-gateway.service ]; then
  echo "[services] found hermes-gateway user service, starting..."
  sudo loginctl enable-linger root >/dev/null 2>&1 || true
  # اطمینان از اجرای user manager
  sudo systemctl start 'user@0.service' >/dev/null 2>&1 || true
  # صبر بیشتر برای ساخته شدن /run/user/0 (قبلاً فقط ۲ ثانیه بود)
  for i in 1 2 3 4 5; do
    if [ -d /run/user/0 ]; then
      echo "[services] /run/user/0 exists after $i tries"
      break
    fi
    echo "[services] waiting for /run/user/0... attempt $i"
    sleep 2
    sudo systemctl start 'user@0.service' >/dev/null 2>&1 || true
  done
  export XDG_RUNTIME_DIR=/run/user/0
  if [ -d "$XDG_RUNTIME_DIR" ]; then
    sudo chown root:root "$XDG_RUNTIME_DIR" 2>/dev/null || true
    sudo chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
    sudo -u root XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user daemon-reload >/dev/null 2>&1 || true
    sudo -u root XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user enable hermes-gateway.service >/dev/null 2>&1 || true
    # تلاش برای استارت
    if sudo -u root XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user start hermes-gateway.service >/dev/null 2>&1; then
      echo "[services] hermes-gateway.service (user): started"
      sleep 2
      sudo -u root XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user status hermes-gateway.service --no-pager -l 2>/dev/null | tail -10 || true
    else
      echo "[services] WARNING: hermes-gateway failed to start via user service, trying direct fallback..."
      sudo -u root XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user status hermes-gateway.service --no-pager -l 2>/dev/null | tail -20 || true
      # Fallback: اجرای مستقیم gateway اگر venv موجود باشد
      if [ -x /usr/local/lib/hermes-agent/venv/bin/python ]; then
        echo "[services] fallback: starting gateway directly via python..."
        sudo -u root bash -c 'XDG_RUNTIME_DIR=/run/user/0 nohup /usr/local/lib/hermes-agent/venv/bin/python -m hermes_cli.main gateway run >/var/log/hermes-gateway.log 2>&1 &' || true
        sleep 3
        if pgrep -f "hermes_cli.*gateway" >/dev/null 2>&1; then
          echo "[services] hermes-gateway: fallback direct start OK"
        else
          echo "[services] WARNING: fallback direct start also failed, checking log..."
          tail -20 /var/log/hermes-gateway.log 2>/dev/null || true
          fail=1
        fi
      else
        echo "[services] WARNING: venv not found at /usr/local/lib/hermes-agent/venv/bin/python — cannot fallback"
        ls -la /usr/local/lib/hermes-agent/ 2>/dev/null | head -n 20 || echo "no hermes-agent dir"
        fail=1
      fi
    fi
  else
    echo "[services] WARNING: /run/user/0 missing after 10s — gateway skipped (non-fatal)"
    echo "[services] trying to start user@0 again..."
    sudo systemctl restart 'user@0.service' >/dev/null 2>&1 || true
    sleep 3
    ls -la /run/user/ 2>/dev/null || echo "no /run/user"
    fail=1
  fi
else
  echo "[services] hermes-gateway.service: unit file absent — skip"
fi

# --- v6.24: نگهبان «اتصال واقعی» گیت‌وی تلگرام ---
# درس ۱۶ سپتامبر: گیت‌وی می‌تواند active باشد ولی هیچ پلتفرمی لود نکرده باشد
# (توکن خالی هنگام بوت) → ربات کر می‌شود بدون هیچ ارور یا کرشی.
# این تایمر هر ۹۰ ثانیه «Connected to Telegram» را بررسی و در صورت نیاز ترمیم می‌کند.
if [ -f "$SCRIPT_DIR/gateway_guard.sh" ]; then
  sudo install -m 0755 "$SCRIPT_DIR/gateway_guard.sh" /usr/local/bin/gateway_guard.sh
  sudo tee /etc/systemd/system/hermes-gateway-guard.service >/dev/null <<'UNIT'
[Unit]
Description=Hermes gateway connectivity guard (real Telegram attach check)
After=network-online.target

[Service]
Type=oneshot
Environment=XDG_RUNTIME_DIR=/run/user/0
ExecStart=/usr/local/bin/gateway_guard.sh
UNIT
  sudo tee /etc/systemd/system/hermes-gateway-guard.timer >/dev/null <<'UNIT'
[Unit]
Description=Run the Hermes gateway connectivity guard every 90s

[Timer]
OnBootSec=120
OnUnitActiveSec=90
AccuracySec=10s
Unit=hermes-gateway-guard.service

[Install]
WantedBy=timers.target
UNIT
  sudo systemctl daemon-reload >/dev/null 2>&1 || true
  sudo systemctl enable --now hermes-gateway-guard.timer >/dev/null 2>&1 \
    && echo "[services] hermes-gateway-guard.timer: enabled (90s)" \
    || echo "[services] WARNING: could not enable hermes-gateway-guard.timer"
else
  echo "[services] gateway_guard.sh not found — guard skipped"
fi

# --- v6.32: نگهبان Tailscale Serve برای OpenClaw ---
# درس ۱۶ سپتامبر (بعدازظهر): با gateway.tailscale.mode=serve، خودِ OpenClaw
# مسیر Serve را هنگام استارت claim می‌کند. اگر tailscaled ری‌استارت شود آن
# claim از بین می‌رود و OpenClaw دوباره نمی‌گیردش؛ فقط لاگ می‌کند
# "serve route claim exited ... until the Gateway restarts".
# نتیجه: سرویس active، لوپ‌بک ۲۰۰، ولی داشبورد HTTPS و اپ موبایل قطع.
if [ -f "$SCRIPT_DIR/openclaw_serve_guard.sh" ]; then
  sudo install -m 0755 "$SCRIPT_DIR/openclaw_serve_guard.sh" \
    /usr/local/bin/openclaw_serve_guard.sh
  sudo tee /etc/systemd/system/openclaw-serve-guard.service >/dev/null <<'UNIT'
[Unit]
Description=OpenClaw Tailscale Serve ingress guard (re-claim after tailscaled restart)
After=network-online.target tailscaled.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/openclaw_serve_guard.sh
UNIT
  sudo tee /etc/systemd/system/openclaw-serve-guard.timer >/dev/null <<'UNIT'
[Unit]
Description=Run the OpenClaw Serve ingress guard every 60s

[Timer]
OnBootSec=90
OnUnitActiveSec=60
AccuracySec=10s
Unit=openclaw-serve-guard.service

[Install]
WantedBy=timers.target
UNIT
  sudo systemctl daemon-reload >/dev/null 2>&1 || true
  sudo systemctl enable --now openclaw-serve-guard.timer >/dev/null 2>&1 \
    && echo "[services] openclaw-serve-guard.timer: enabled (60s)" \
    || echo "[services] WARNING: could not enable openclaw-serve-guard.timer"
else
  echo "[services] openclaw_serve_guard.sh not found — serve guard skipped"
fi

# --- راستی‌آزمایی ---
echo "[services] status:"
sudo systemctl is-active hermes-dashboard.service hermes-tunnel.service 2>/dev/null || true
sudo -u root XDG_RUNTIME_DIR=/run/user/0 systemctl --user is-active hermes-gateway.service 2>/dev/null || echo "gateway user service not active (checking pgrep fallback...)"
pgrep -a -f "hermes.*gateway\|hermes_cli.*gateway" 2>/dev/null || echo "no gateway pgrep"

if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ':9119'; then
  echo "[services] dashboard port 9119: LISTENING"
else
  echo "[services] dashboard port 9119: not listening (yet) - may need more time"
fi

if [ "$fail" -ne 0 ]; then
  echo "[services] DONE with warnings (boot continues)"
else
  echo "[services] DONE — all requested services started"
fi
exit 0
