#!/usr/bin/env bash
# start-services.sh — استارت سرویس‌های ماندگار بعد از restore (v6.4 - gateway fix)
# v6.4: رفع مشکل hermes-gateway که بین ران‌ها fail می‌شد
#   - صبر بیشتر برای user@0.service و /run/user/0
#   - fallback اجرای مستقیم gateway اگر user service fail شد
#   - لاگ دقیق‌تر برای دیباگ
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail=0

# Retired by explicit user request (2026-09-28): OpenClaw, Pi/Pi Web and AI Hub.
# This runs after every restore as a defence-in-depth barrier: even an old state
# snapshot cannot revive the retired programs on a later GitHub runner.
retire_removed_ai_components() {
  local u p
  for u in openclaw-gateway.service pi-web.service aihub.service \
           openclaw-serve-guard.service openclaw-serve-guard.timer; do
    sudo systemctl disable --now "$u" >/dev/null 2>&1 || true
  done
  # Explicitly remove old units before daemon-reload. The replacement
  # tailscale-serve-guard maintains only the services which remain supported.
  sudo rm -f /etc/systemd/system/openclaw-gateway.service \
             /etc/systemd/system/pi-web.service \
             /etc/systemd/system/aihub.service \
             /etc/systemd/system/openclaw-serve-guard.service \
             /etc/systemd/system/openclaw-serve-guard.timer \
             /usr/local/bin/openclaw_serve_guard.sh
  sudo rm -f /etc/pi-web.env /usr/local/bin/openclaw /usr/local/bin/pi /usr/local/bin/pi-web
  sudo rm -rf /opt/openclaw-node /opt/openclaw-app /root/.openclaw /root/.pi /opt/aihub \
              /usr/local/lib/node_modules/openclaw \
              /usr/local/lib/node_modules/@earendil-works/pi-coding-agent \
              /usr/local/lib/node_modules/@agegr/pi-web
  # A legacy state snapshot can retain a Serve handler for OpenClaw under
  # an old MagicDNS alias. Serve has no per-host delete command, so migrate the
  # local Serve config exactly once: reset it, then the retained-dashboard and
  # Hermes guards later in this boot rebuild only the supported routes.
  local _serve_retire_marker=/var/lib/tailscale/retired-ai-serve-cleaned-v1
  if [ ! -e "$_serve_retire_marker" ] && command -v tailscale >/dev/null 2>&1; then
    sudo tailscale serve reset >/dev/null 2>&1 || true
    sudo install -d -m 700 /var/lib/tailscale
    sudo touch "$_serve_retire_marker"
  fi
  # They were installed globally with npm on earlier runners. Removal is
  # intentionally non-fatal: paths have already been removed above.
  if command -v npm >/dev/null 2>&1; then
    sudo npm uninstall -g @earendil-works/pi-coding-agent @agegr/pi-web >/dev/null 2>&1 || true
  fi
  sudo systemctl daemon-reload >/dev/null 2>&1 || true
}
retire_removed_ai_components

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



# --- گاوصندوق اسرار: پیش از هر سرویسی ------------------------------------
# سه سازوکار مستقل .env را خالی می‌کنند: پنجرهٔ blanking خود save.sh،
# secrets_inject که فقط ۳ کلید می‌شناسد، و نصب‌کنندهٔ هرمس که فایل را از
# روی قالب بازمی‌سازد. این باید **قبل** از استارت سرویس‌ها اجرا شود،
# وگرنه سرویس با کلید خالی بالا می‌آید و خاموش می‌شکند.
if [ -f "$SCRIPT_DIR/env_vault.py" ]; then
  install -m 755 "$SCRIPT_DIR/env_vault.py" /usr/local/bin/env_vault.py
  python3 /usr/local/bin/env_vault.py 2>&1 | tail -3 || true
  cat > /etc/systemd/system/env-vault.service <<'EOG'
[Unit]
Description=Hermes/OmniRoute env vault (restore blanked or missing secrets)
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/bin/env_vault.py
EOG
  cat > /etc/systemd/system/env-vault.timer <<'EOG'
[Unit]
Description=Run the env vault every 3 minutes
[Timer]
OnBootSec=45
OnUnitActiveSec=3min
AccuracySec=20s
[Install]
WantedBy=timers.target
EOG
  systemctl daemon-reload
  systemctl enable --now env-vault.timer >/dev/null 2>&1 \
    && echo "[services] env-vault: timer armed"
fi

# نگهبان‌ها را همین‌جا مسلح کن، نه داخل ensure_*.
# درس: تابعی که ممکن است زودهنگام return کند جای نصب نگهبان نیست —
# دو بار پشت سر هم hermes-serve بعد از تعویض رانر بالا نیامد چون
# تایمرش اصلاً ساخته نشده بود.
for _g in hermes_serve_guard omniroute_guard; do
  [ -f "$SCRIPT_DIR/${_g}.sh" ] || continue
  install -m 755 "$SCRIPT_DIR/${_g}.sh" "/usr/local/bin/${_g}.sh"
  _unit="${_g//_/-}"
  cat > "/etc/systemd/system/${_unit}.service" <<EOG
[Unit]
Description=${_g} (self-heal)
[Service]
Type=oneshot
ExecStart=/usr/local/bin/${_g}.sh
EOG
  cat > "/etc/systemd/system/${_unit}.timer" <<EOG
[Unit]
Description=Run ${_g} periodically
[Timer]
OnBootSec=60
OnUnitActiveSec=4min
AccuracySec=30s
[Install]
WantedBy=timers.target
EOG
  systemctl daemon-reload
  systemctl enable --now "${_unit}.timer" >/dev/null 2>&1 \
    && echo "[services] ${_unit}: timer armed"
  # یک بار همین حالا اجرا کن تا منتظر تیک اول نمانیم
  "/usr/local/bin/${_g}.sh" >/dev/null 2>&1 || true
done

# --- OmniRoute: دروازهٔ AI روی ۲۰۱۳۰ ----------------------------------------
# عمداً ۲۰۱۲۸ نیست: آن پورت در اختیار 9router است و هر چهار ایجنت به آن
# وصل‌اند. دو دروازه کنار هم زندگی می‌کنند.
ensure_omniroute() {
  command -v omniroute >/dev/null 2>&1 || {
    echo "[services] omniroute: not installed, installing"
    CI=1 OMNIROUTE_SKIP_POSTINSTALL=1 timeout 900 npm install -g omniroute \
      --no-fund --no-audit >/tmp/omniroute-install.log 2>&1 \
      || { echo "[services] omniroute: install FAILED"; tail -5 /tmp/omniroute-install.log; return 0; }
  }
  mkdir -p /root/.omniroute

  # ⚠️ خطرناک‌ترین بخش این تابع.
  # OmniRoute اعتبارنامهٔ ارائه‌دهنده‌ها را با AES رمز می‌کند و کلیدش از
  # همین secretها می‌آید. اگر دیتابیس وجود داشته باشد و ما secret تازه
  # بسازیم، همهٔ کلیدهای کاربر **غیرقابل‌بازگشایی** می‌شوند — یعنی
  # پیکربندی‌اش را بی‌سروصدا نابود کرده‌ایم.
  # پس: فقط وقتی .env می‌سازیم که هیچ دیتابیسی نباشد (نصب واقعاً تازه).
  if [ ! -s /root/.omniroute/.env ]; then
    if [ -s /root/.omniroute/storage.sqlite ]; then
      # دیتابیس هست ولی .env نیست ⇒ حتماً یک بازگردانی ناقص رخ داده.
      # از نسخهٔ پشتیبانِ secret استفاده کن؛ اگر آن هم نبود، **چیزی نساز**
      # و بلند فریاد بزن. ساختن secret تازه اینجا یعنی از دست رفتن داده.
      if [ -s /root/.omniroute-secrets ]; then
        cp /root/.omniroute-secrets /root/.omniroute/.env
        chmod 600 /root/.omniroute/.env
        echo "[services] omniroute: .env restored from secret backup"
      else
        echo "[services] omniroute: ✖ DB present but .env AND secret backup are gone."
        echo "[services] omniroute:   NOT generating new secrets — that would make"
        echo "[services] omniroute:   every stored provider credential undecryptable."
        echo "[services] omniroute:   Restore /root/.omniroute from a backup."
        return 0
      fi
    else
      echo "[services] omniroute: fresh install — generating .env"
      _jwt=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 40)
      _aks=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 40)
      cat > /root/.omniroute/.env <<EOF
PORT=20130
HOSTNAME=127.0.0.1
OMNIROUTE_SERVER_HOST=127.0.0.1
DATA_DIR=/root/.omniroute
NODE_ENV=production
JWT_SECRET=${_jwt}
API_KEY_SECRET=${_aks}
INITIAL_PASSWORD=${DASHBOARD_PASSWORD:-hamidgh69}
NEXT_PUBLIC_BASE_URL=http://127.0.0.1:20130
APP_LOG_TO_FILE=false
EOF
      chmod 600 /root/.omniroute/.env
    fi
  fi
  # نسخهٔ دوم از secretها، جدا از پوشهٔ دیتابیس — اگر آن پوشه آسیب ببیند
  # دست‌کم کلیدها برای بازگشایی دیتابیس باقی می‌مانند.
  if ! cmp -s /root/.omniroute/.env /root/.omniroute-secrets 2>/dev/null; then
    cp /root/.omniroute/.env /root/.omniroute-secrets 2>/dev/null
    chmod 600 /root/.omniroute-secrets 2>/dev/null
  fi
  grep -q OMNIROUTE_SERVER_HOST /root/.omniroute/.env || \
    echo "OMNIROUTE_SERVER_HOST=127.0.0.1" >> /root/.omniroute/.env

  if [ ! -f /etc/systemd/system/omniroute.service ]; then
    cat > /etc/systemd/system/omniroute.service <<'EOF'
[Unit]
Description=OmniRoute AI Gateway (port 20130)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/root/.omniroute
EnvironmentFile=/root/.omniroute/.env
ExecStart=/usr/local/bin/omniroute
Restart=always
RestartSec=5
KillSignal=SIGINT
TimeoutStopSec=40
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
  fi
  systemctl enable omniroute >/dev/null 2>&1 || true
  start_system omniroute.service
  for _i in $(seq 1 12); do
    curl -fsS -m 3 -o /dev/null http://127.0.0.1:20130/ 2>/dev/null && break
    sleep 5
  done
  # مسیر Serve بعد از چرخش رانر/ری‌استارت tailscaled از بین می‌رود
  if ! tailscale serve status 2>/dev/null | grep -q '127.0.0.1:20130'; then
    tailscale serve --bg --https=9447 http://127.0.0.1:20130 >/dev/null 2>&1 \
      && echo "[services] omniroute: tailscale serve 9447 re-established" \
      || echo "[services] omniroute: WARNING tailscale serve 9447 failed"
  fi
  if [ -f "$SCRIPT_DIR/omniroute_guard.sh" ]; then
    install -m 755 "$SCRIPT_DIR/omniroute_guard.sh" /usr/local/bin/omniroute_guard.sh
    cat > /etc/systemd/system/omniroute-guard.service <<'EOG'
[Unit]
Description=OmniRoute guard (secrets + service + serve + daily snapshot)
[Service]
Type=oneshot
ExecStart=/usr/local/bin/omniroute_guard.sh
EOG
    cat > /etc/systemd/system/omniroute-guard.timer <<'EOG'
[Unit]
Description=Run OmniRoute guard every 5 minutes
[Timer]
OnBootSec=120
OnUnitActiveSec=5min
AccuracySec=30s
[Install]
WantedBy=timers.target
EOG
    systemctl daemon-reload
    systemctl enable --now omniroute-guard.timer >/dev/null 2>&1 \
      && echo "[services] omniroute: guard timer armed"
  fi
  if curl -fsS -m 4 -o /dev/null http://127.0.0.1:20130/ 2>/dev/null; then
    echo "[services] omniroute: healthy on 127.0.0.1:20130 (https :9447 via tailnet)"
  else
    echo "[services] omniroute: not answering yet — Restart=always keeps retrying"
  fi
}
ensure_omniroute


# --- Hermes backend برای Hermes Desktop (اتصال راه‌دور) -----------------------
# این *جدا* از gateway پیام‌رسان است: gateway کار تلگرام/دیسکورد را می‌کند،
# و `hermes serve` همان چیزی است که اپ دسکتاپ به آن وصل می‌شود. هر دو یک
# ~/.hermes مشترک دارند.
ensure_hermes_serve() {
  local TSIP
  TSIP=$(tailscale ip -4 2>/dev/null | head -1)
  [ -n "$TSIP" ] || { echo "[services] hermes-serve: no tailscale IP yet, skip"; return 0; }
  [ -x /usr/local/lib/hermes-agent/venv/bin/python ] || {
    echo "[services] hermes-serve: hermes venv missing, skip"; return 0; }

  # ⚠️ bind غیرلوپ‌بک دروازهٔ احراز هویت را فعال می‌کند و بدون provider
  # سرویس عمداً بالا نمی‌آید (fail closed).
  if ! grep -q HERMES_DASHBOARD_BASIC_AUTH_USERNAME /root/.hermes/.env 2>/dev/null; then
    _sec=$(openssl rand -base64 32 2>/dev/null || head -c 32 /dev/urandom | base64)
    {
      echo ""
      echo "# --- Hermes Desktop (remote backend) ---"
      echo "HERMES_DASHBOARD_BASIC_AUTH_USERNAME=hamid"
      echo "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=${DASHBOARD_PASSWORD:-hamidgh69}"
      echo "HERMES_DASHBOARD_BASIC_AUTH_SECRET=${_sec}"
    } >> /root/.hermes/.env
    chmod 600 /root/.hermes/.env
  fi

  # آدرس tailnet هر بوت ثابت است ولی یونیت را بازنویسی می‌کنیم تا اگر
  # روزی عوض شد، سرویس روی آدرس مرده گیر نکند.
  cat > /etc/systemd/system/hermes-serve.service <<EOF
[Unit]
Description=Hermes backend for Hermes Desktop (remote gateway) — tailnet only
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/root/.hermes
EnvironmentFile=/root/.hermes/.env
Environment="HERMES_HOME=/root/.hermes"
Environment="PATH=/usr/local/lib/hermes-agent/venv/bin:/usr/local/bin:/root/.local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="VIRTUAL_ENV=/usr/local/lib/hermes-agent/venv"
ExecStart=/usr/local/lib/hermes-agent/venv/bin/python -m hermes_cli.main serve --host ${TSIP} --port 9122 --skip-build
Restart=always
RestartSec=8
KillMode=mixed
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable hermes-serve >/dev/null 2>&1 || true
  start_system hermes-serve.service
  for _i in $(seq 1 10); do
    curl -fsS -m 3 -o /dev/null "http://${TSIP}:9122/api/status" 2>/dev/null && break
    sleep 4
  done
  # Funnel: دسترسی عمومی بدون نیاز به Tailscale روی دستگاه کاربر.
  # اگر facade عمومی nginx از state برگردد، public_webui_guard تنها مالک
  # Funnel است تا مسیر مستقیمِ بدون Basic Auth حتی موقتاً جایگزین نشود.
  # ⚠️ نگهبان DNS-rebinding بدون dashboard.public_url هر درخواستی را که
  # Host‌اش با آدرس bind فرق دارد با ۴۰۰ رد می‌کند.
  if [ ! -f /etc/nginx/sites-enabled/public-webui ] && ! tailscale funnel status 2>/dev/null | grep -q ':10000'; then
    tailscale funnel --bg --https=10000 "http://${TSIP}:9122" >/dev/null 2>&1 \
      && echo "[services] hermes-serve: funnel 10000 re-established" \
      || echo "[services] hermes-serve: WARNING funnel failed (node may need the funnel nodeAttr)"
  fi
  # نگهبان: دو بار پشت سر هم بعد از تعویض رانر این اتصال خاموش شکست —
  # یک‌بار چون یونیتِ بازگردانده‌شده enabled بود ولی استارت نشده بود، و
  # یک‌بار چون خودِ هرمس موقع مهاجرت پیکربندی public_url را انداخته بود.
  # اتکا به یک‌بار اجرا در بوت کافی نیست.
  if [ -f "$SCRIPT_DIR/hermes_serve_guard.sh" ]; then
    install -m 755 "$SCRIPT_DIR/hermes_serve_guard.sh" /usr/local/bin/hermes_serve_guard.sh
    cat > /etc/systemd/system/hermes-serve-guard.service <<'EOG'
[Unit]
Description=Hermes Desktop backend guard (public_url + service + funnel)
[Service]
Type=oneshot
ExecStart=/usr/local/bin/hermes_serve_guard.sh
EOG
    cat > /etc/systemd/system/hermes-serve-guard.timer <<'EOG'
[Unit]
Description=Run hermes-serve guard every 4 minutes
[Timer]
OnBootSec=90
OnUnitActiveSec=4min
AccuracySec=30s
[Install]
WantedBy=timers.target
EOG
    systemctl daemon-reload
    systemctl enable --now hermes-serve-guard.timer >/dev/null 2>&1 \
      && echo "[services] hermes-serve: guard timer armed"
  fi
  if curl -fsS -m 4 -o /dev/null "http://${TSIP}:9122/api/status" 2>/dev/null; then
    echo "[services] hermes-serve: ready on ${TSIP}:9122 (Hermes Desktop remote gateway)"
  else
    echo "[services] hermes-serve: not answering yet — Restart=always keeps retrying"
  fi
}
ensure_hermes_serve

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

# --- نگهبان عمومی Tailscale Serve برای پنل‌های باقی‌مانده ---
# OpenClaw/Pi/AI Hub retired هستند؛ این نگهبان فقط مسیرهای CloudCLI, Hermes,
# 9Router و OmniRoute را بعد از restart شدن tailscaled بازمی‌گرداند.
if [ -f "$SCRIPT_DIR/tailscale_serve_guard.sh" ]; then
  sudo install -m 0755 "$SCRIPT_DIR/tailscale_serve_guard.sh" \
    /usr/local/bin/tailscale_serve_guard.sh
  sudo tee /etc/systemd/system/tailscale-serve-guard.service >/dev/null <<'UNIT'
[Unit]
Description=Tailscale Serve guard for retained dashboards
After=network-online.target tailscaled.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/tailscale_serve_guard.sh
UNIT
  sudo tee /etc/systemd/system/tailscale-serve-guard.timer >/dev/null <<'UNIT'
[Unit]
Description=Run the retained-dashboard Serve guard every 60s

[Timer]
OnBootSec=90
OnUnitActiveSec=60
AccuracySec=10s
Unit=tailscale-serve-guard.service

[Install]
WantedBy=timers.target
UNIT
  sudo systemctl daemon-reload >/dev/null 2>&1 || true
  sudo systemctl enable --now tailscale-serve-guard.timer >/dev/null 2>&1 \
    && echo "[services] tailscale-serve-guard.timer: enabled (60s)" \
    || echo "[services] WARNING: could not enable tailscale-serve-guard.timer"
else
  echo "[services] tailscale_serve_guard.sh not found — guard skipped"
fi

# --- public Funnel facade: nginx Basic Auth before every internet route ---
# The auth file is intentionally not generated here. It is created only during
# the explicit, user-approved public deployment and then persisted in state.
# If it is absent, the guard fails closed and never invents an internet password.
if [ -f "$SCRIPT_DIR/public_webui_guard.sh" ]; then
  sudo install -m 0755 "$SCRIPT_DIR/public_webui_guard.sh" /usr/local/bin/public_webui_guard.sh
  sudo tee /etc/systemd/system/public-webui-guard.service >/dev/null <<'UNIT'
[Unit]
Description=Authenticated public web UI Funnel guard
After=network-online.target tailscaled.service nginx.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/public_webui_guard.sh
UNIT
  sudo tee /etc/systemd/system/public-webui-guard.timer >/dev/null <<'UNIT'
[Unit]
Description=Refresh authenticated public Funnel routes every two minutes

[Timer]
OnBootSec=120
OnUnitActiveSec=2min
AccuracySec=20s
Unit=public-webui-guard.service

[Install]
WantedBy=timers.target
UNIT
  sudo systemctl daemon-reload >/dev/null 2>&1 || true
  sudo systemctl enable --now public-webui-guard.timer >/dev/null 2>&1 \
    && echo "[services] public-webui-guard.timer: enabled" \
    || echo "[services] WARNING: could not enable public-webui-guard.timer"
  sudo /usr/local/bin/public_webui_guard.sh >/dev/null 2>&1 || true
else
  echo "[services] public_webui_guard.sh not found — public facade skipped"
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
