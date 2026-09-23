#!/bin/bash
# ============================================================================
# provision.sh — v4.5.5 hermes venv symlink fix
#   - v4.5.4: fast path if staged binary exists
#   - v4.5.5: check venv python validity - symlink to uv may be broken if uv not persisted
#             if venv/bin/python missing or broken -> reinstall
# ============================================================================
set -uo pipefail
LOG_DIR=/tmp/provision
mkdir -p "$LOG_DIR"
log()  { echo "[provision $(date -u '+%T')] $*"; }
note() { echo "[provision] $*" | tee -a "${LOG_DIR}/summary.txt"; }
: > "${LOG_DIR}/summary.txt"
SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

RESTORE_ROOT="/tmp/persist-restore"

has_hermes_data() {
  [ -d /root/.hermes ] || [ -d "$RESTORE_ROOT/root/.hermes" ]
}
is_venv_valid() {
  local venv_python="/usr/local/lib/hermes-agent/venv/bin/python"
  local staged_venv="$RESTORE_ROOT/usr/local/lib/hermes-agent/venv/bin/python"
  # v6.22: اعتبارسنجی «کارکردی» — فقط وجود فایل کافی نیست. نصب‌های جدید
  # hermes به /usr/bin/python3 سیستمی لینک می‌شوند (نه uv)، و نصب خراب
  # (آپدیت نیمه‌کاره) پوشه‌ی hermes-agent را حذف می‌کند در حالی که
  # /usr/local/bin/hermes باقی می‌ماند. پس واقعاً اجرا را تست می‌کنیم.
  if [ -e "$venv_python" ]; then
    local target
    target=$(readlink -f "$venv_python" 2>/dev/null || echo "$venv_python")
    if [ -x "$target" ] && "$venv_python" -c 'import sys' >/dev/null 2>&1; then
      # ماژول اصلی هم باید قابل import باشد، وگرنه نصب ناقص است
      if [ -f /usr/local/lib/hermes-agent/hermes ] || [ -d /usr/local/lib/hermes-agent/hermes_cli ]; then
        return 0
      fi
    fi
    return 1
  fi
  # staged (از آرشیو state) — فقط وجود را می‌سنجیم چون هنوز apply نشده
  if [ -e "$staged_venv" ] && [ -d "$RESTORE_ROOT/usr/local/lib/hermes-agent" ]; then
    return 0
  fi
  return 1
}
has_hermes_binary_live() {
  [ -x /usr/local/bin/hermes ] && [ -d /usr/local/lib/hermes-agent ] && is_venv_valid
}
has_hermes_binary_staged() {
  [ -x "$RESTORE_ROOT/usr/local/bin/hermes" ] && [ -d "$RESTORE_ROOT/usr/local/lib/hermes-agent" ] && [ -e "$RESTORE_ROOT/usr/local/lib/hermes-agent/venv/bin/python" ]
}
has_hermes_legacy() {
  [ -x /root/.hermes/hermes-agent/hermes ] || [ -d /root/.hermes/hermes-agent/.git ] || [ -x "$RESTORE_ROOT/root/.hermes/hermes-agent/hermes" ]
}
has_9router_data() {
  [ -d /root/.9router ] || [ -d /home/Hamid/.9router ] || [ -d "$RESTORE_ROOT/root/.9router" ] || [ -d "$RESTORE_ROOT/home/Hamid/.9router" ]
}
has_9router_binary() {
  [ -x /usr/local/bin/9router ] || [ -x "$RESTORE_ROOT/usr/local/bin/9router" ]
}

ensure_npm() {
  command -v npm >/dev/null 2>&1 && return 0
  command -v nodejs >/dev/null 2>&1 || $SUDO apt-get install -y -qq nodejs npm >/dev/null 2>&1 || true
  command -v npm >/dev/null 2>&1
}

provision_9router() {
  if has_9router_binary; then
    note "9router: present — kept (Mode 2)"
  else
    if has_9router_data; then
      log "9router: data exists (live or staged) but binary missing — reinstalling (recovery)..."
      if ensure_npm && timeout 300 $SUDO env PATH="$PATH" npm install -g 9router >"${LOG_DIR}/9router.log" 2>&1; then
        note "9router: REINSTALLED (recovery)"
      else
        note "9router: recovery FAILED"
        tail -20 "${LOG_DIR}/9router.log" 2>/dev/null | tee -a "${LOG_DIR}/summary.txt"
      fi
    else
      note "9router: not present — NOT reinstalling (Mode 2)"
    fi
  fi
}

# ---------------------------------------------------------------------------
# OpenClaw (v6.26)
# معماری ماندگاری — عمداً مثل 9router: «داده می‌ماند، کد بازنصب می‌شود».
#   * دادهٔ کاربر  : /root/.openclaw  → در آرشیو state حفظ می‌شود
#                    (agents/ = سشن‌ها و حافظه، workspace/، openclaw.json،
#                     .gateway-token، دستگاه‌های pair شده)
#   * کد و رانتایم : /opt/openclaw-node (Node 24) + /opt/openclaw-app
#                    → آرشیو نمی‌شوند (۷۵۰MB و پر از node_modules) و اینجا
#                      در صورت نبود بازنصب می‌شوند.
# نکتهٔ مهم: OpenClaw حداقل Node 24 می‌خواهد ولی Node سیستمی روی ۲۲ می‌ماند،
# چون 9router به ماژول بومی better-sqlite3 کامپایل‌شده برای ABI نود ۲۲ وابسته
# است. پس OpenClaw رانتایم جدا و ایزولهٔ خودش را دارد.
OPENCLAW_NODE_DIR=/opt/openclaw-node
OPENCLAW_APP_DIR=/opt/openclaw-app

has_openclaw_data() {
  [ -f /root/.openclaw/openclaw.json ] || [ -f "$RESTORE_ROOT/root/.openclaw/openclaw.json" ]
}
has_openclaw_runtime() {
  [ -x "$OPENCLAW_NODE_DIR/bin/node" ] && \
  [ -f "$OPENCLAW_APP_DIR/lib/node_modules/openclaw/openclaw.mjs" ]
}

install_openclaw_node() {
  [ -x "$OPENCLAW_NODE_DIR/bin/node" ] && return 0
  local v
  v=$(curl -s --max-time 30 https://nodejs.org/dist/index.json 2>/dev/null | python3 -c "
import sys,json
try:
    for r in json.load(sys.stdin):
        if int(r['version'].lstrip('v').split('.')[0])==24:
            print(r['version']); break
except Exception: pass
" 2>/dev/null)
  [ -z "$v" ] && v="v24.21.0"   # fallback اگر API در دسترس نبود
  $SUDO mkdir -p "$OPENCLAW_NODE_DIR"
  curl -sL --max-time 300 -o /tmp/ocnode.tar.xz \
    "https://nodejs.org/dist/$v/node-$v-linux-x64.tar.xz" || return 1
  $SUDO tar -xJf /tmp/ocnode.tar.xz -C "$OPENCLAW_NODE_DIR" --strip-components=1 || return 1
  rm -f /tmp/ocnode.tar.xz
  [ -x "$OPENCLAW_NODE_DIR/bin/node" ]
}

write_openclaw_wrapper() {
  $SUDO tee /usr/local/bin/openclaw >/dev/null <<WRAP
#!/bin/sh
# OpenClaw با رانتایم Node 24 اختصاصی اجرا می‌شود تا Node 22 سیستمی
# (وابستگی 9router / better-sqlite3) دست‌نخورده بماند.
export PATH="$OPENCLAW_NODE_DIR/bin:\$PATH"
export OPENCLAW_STATE_DIR="\${OPENCLAW_STATE_DIR:-/root/.openclaw}"
exec "$OPENCLAW_NODE_DIR/bin/node" "$OPENCLAW_APP_DIR/lib/node_modules/openclaw/openclaw.mjs" "\$@"
WRAP
  $SUDO chmod +x /usr/local/bin/openclaw
}

provision_openclaw() {
  if ! has_openclaw_data; then
    note "openclaw: no data — NOT installing (Mode 2)"
    return 0
  fi
  if has_openclaw_runtime; then
    write_openclaw_wrapper
    note "openclaw: runtime present — kept"
  else
    log "openclaw: data exists but runtime missing — reinstalling (expected after a new runner)..."
    if install_openclaw_node; then
      if timeout 900 $SUDO env PATH="$OPENCLAW_NODE_DIR/bin:$PATH" \
           "$OPENCLAW_NODE_DIR/bin/npm" install -g --prefix "$OPENCLAW_APP_DIR" \
           openclaw@latest >"${LOG_DIR}/openclaw.log" 2>&1 && has_openclaw_runtime; then
        write_openclaw_wrapper
        note "openclaw: REINSTALLED (data preserved)"
      else
        note "openclaw: npm install FAILED"
        tail -20 "${LOG_DIR}/openclaw.log" 2>/dev/null | tee -a "${LOG_DIR}/summary.txt"
        return 0
      fi
    else
      note "openclaw: Node 24 download FAILED"
      return 0
    fi
  fi

  # سرویس دائمی — در هر بوت بازنویسی می‌شود تا همیشه درست باشد
  $SUDO tee /etc/systemd/system/openclaw-gateway.service >/dev/null <<UNIT
[Unit]
Description=OpenClaw Gateway (AI agent, 9router provider)
After=network-online.target tailscaled.service 9router.service
Wants=network-online.target

[Service]
Type=simple
User=root
Environment=PATH=$OPENCLAW_NODE_DIR/bin:/usr/local/bin:/usr/bin:/bin
Environment=HOME=/root
Environment=OPENCLAW_STATE_DIR=/root/.openclaw
Environment=NODE_ENV=production
WorkingDirectory=/root/.openclaw
ExecStart=$OPENCLAW_NODE_DIR/bin/node $OPENCLAW_APP_DIR/lib/node_modules/openclaw/openclaw.mjs gateway run --port 18789
Restart=always
RestartSec=5
RestartPreventExitStatus=78
TimeoutStopSec=60
KillMode=mixed
StandardOutput=append:/var/log/openclaw-gateway.log
StandardError=append:/var/log/openclaw-gateway.log

[Install]
WantedBy=multi-user.target
UNIT
  $SUDO systemctl daemon-reload >/dev/null 2>&1 || true
  $SUDO systemctl enable openclaw-gateway.service >/dev/null 2>&1 || true
  note "openclaw: service unit written + enabled"

  # v6.28: اپ‌های موبایل/دسکتاپ برای pairing حتماً wss:// معتبر می‌خواهند و با
  # http روی IP تیل‌نت کد اتصال صادر نمی‌شود. Tailscale Serve یک گواهی واقعی
  # روی نام MagicDNS می‌دهد. نام گره ثابت است (هویت در /var/lib/tailscale حفظ
  # می‌شود) پس آدرس بین رانرها عوض نمی‌شود و کدهای قبلی معتبر می‌مانند.
  local _dn
  _dn=$(tailscale status --json 2>/dev/null | python3 -c "
import sys,json
try: print(json.load(sys.stdin).get('Self',{}).get('DNSName','').rstrip('.'))
except Exception: pass
" 2>/dev/null)
  if [ -n "$_dn" ]; then
    timeout 90 tailscale cert "$_dn" >/dev/null 2>&1 || true

    if [ -x /usr/local/bin/openclaw ]; then
      local _oc=/usr/local/bin/openclaw
      # v6.34 — معماری نهایی Serve:
      #   * حالت داخلی OpenClaw (gateway.tailscale.mode=serve) claim را فقط
      #     in-process نگه می‌دارد. هر Stop/Start سرویس tailscaled (که هر
      #     اجرای ops-exec و واچ‌داگ انجام می‌دهد) آن را می‌کشد و OpenClaw
      #     دوباره نمی‌گیردش ⇒ داشبورد هر ~۱۰ دقیقه می‌مرد.
      #   * پس Serve را دستی و ماندگار می‌سازیم: در /var/lib/tailscale ذخیره
      #     می‌شود که خودش یکی از روت‌های persist است.
      #   * علت شکست قبلیِ همین روش، نبودِ gateway.trustedProxies بود
      #     (proxy_attribution_required) که حالا تنظیم می‌شود.
      timeout 60 $_oc config set gateway.bind loopback >/dev/null 2>&1 || true
      timeout 60 $_oc config set gateway.tailscale.mode off >/dev/null 2>&1 || true
      timeout 60 $_oc config set --json gateway.trustedProxies \
        '["127.0.0.1/32","::1/128"]' >/dev/null 2>&1 || true
      timeout 60 $_oc config set gateway.auth.allowTailscale true >/dev/null 2>&1 || true
      timeout 60 $_oc config set --json gateway.controlUi.allowedOrigins \
        "[\"https://$_dn\",\"http://127.0.0.1:18789\",\"http://localhost:18789\"]" \
        >/dev/null 2>&1 || true
      # هر دستگاهی که از داخل tailnet بیاید خودکار تأیید شود؛ وگرنه اپ موبایل
      # با http101 403 forbidden در صف Pending می‌ماند.
      timeout 60 $_oc config set gateway.nodes.pairing.autoApproveLocal true \
        >/dev/null 2>&1 || true
      timeout 60 $_oc config set --json gateway.nodes.pairing.autoApproveCidrs \
        '["100.64.0.0/10","127.0.0.1/32","::1/128"]' >/dev/null 2>&1 || true
      # آدرس pairing باید در کانفیگ بماند وگرنه openclaw qr خطا می‌دهد
      timeout 60 $_oc config set \
        plugins.entries.device-pair.config.publicUrl "wss://$_dn" >/dev/null 2>&1 || true

      # Serve ماندگار (idempotent): فقط اگر مسیر نبود بسازش
      if ! timeout 30 tailscale serve status 2>/dev/null | grep -q '18789'; then
        timeout 90 tailscale serve --bg --https=443 http://127.0.0.1:18789 >/dev/null 2>&1 \
          && note "openclaw: persistent tailscale serve installed (https://$_dn)" \
          || note "openclaw: tailscale serve FAILED"
      else
        note "openclaw: persistent tailscale serve already present"
      fi
      note "openclaw: proxy trust + tailnet auto-approve applied"
    fi
  else
    note "openclaw: no tailscale DNS name — serve skipped"
  fi
}

provision_hermes() {
  if has_hermes_binary_live; then
    note "hermes: present — kept (Mode 2)"
    return 0
  fi
  if has_hermes_binary_staged; then
    note "hermes: present staged — kept (will be applied, no reinstall needed) (Mode 2)"
    return 0
  fi
  if has_hermes_legacy; then
    note "hermes: present legacy — kept (Mode 2)"
    return 0
  fi
  if has_hermes_data; then
    # check if venv is broken
    if [ -d /usr/local/lib/hermes-agent ] && ! is_venv_valid; then
      log "hermes: venv broken (symlink to uv missing) — will reinstall to fix..."
    else
      log "hermes: data exists (live or staged at $RESTORE_ROOT) but binary missing — reinstalling (recovery)..."
    fi
    curl -fsSL --max-time 60 https://hermes-agent.nousresearch.com/install.sh -o /tmp/hermes-install.sh || { note "hermes: download FAILED"; return 1; }
    timeout 1500 $SUDO env HERMES_HOME=/root/.hermes bash /tmp/hermes-install.sh --non-interactive --skip-browser --skip-computer-use >"${LOG_DIR}/hermes.log" 2>&1
    rc=$?
    if [ $rc -eq 0 ] && { [ -x /usr/local/bin/hermes ] || [ -x /root/.hermes/hermes-agent/hermes ] || [ -d /usr/local/lib/hermes-agent ]; }; then
      note "hermes: REINSTALLED (recovery, binary restored)"
      # verify venv now valid
      if is_venv_valid; then
        log "hermes: venv valid after reinstall"
      else
        log "hermes: WARNING venv still invalid after reinstall"
      fi
      # v6.23: هر نصب/آپدیت، فایل‌های پایتون را روی دیسک عوض می‌کند، اما
      # پروسه‌ی gateway که از قبل در حال اجراست ماژول‌های قدیمی را در حافظه
      # نگه می‌دارد. چون بخشی از importها تنبل (lazy) هستند — مثل
      # hermes_cli.model_switch که فقط هنگام دستور /model بارگذاری می‌شود —
      # ناسازگاری بعداً و به شکل «ImportError: cannot import name …» در
      # تلگرام ظاهر می‌شود. پس بعد از هر نصب، bytecode کهنه پاک و gateway
      # ری‌استارت می‌شود. فایل‌های سشن دست نمی‌خورند.
      find /usr/local/lib/hermes-agent -maxdepth 3 -name '__pycache__' -type d \
        -not -path '*/venv/*' -not -path '*/node_modules/*' -exec rm -rf {} + 2>/dev/null
      if pgrep -f "hermes_cli.main gateway" >/dev/null 2>&1; then
        log "hermes: restarting gateway so it picks up the new code (sessions preserved)"
        XDG_RUNTIME_DIR=/run/user/0 $SUDO -u root systemctl --user restart hermes-gateway.service >/dev/null 2>&1 \
          || { pkill -f "hermes_cli.main gateway" 2>/dev/null; sleep 2; }
      fi
    else
      note "hermes: recovery FAILED (rc=$rc)"
      tail -30 "${LOG_DIR}/hermes.log" 2>/dev/null | tee -a "${LOG_DIR}/summary.txt"
    fi
  else
    note "hermes: not present and no data — NOT reinstalling (Mode 2, user never installed)"
  fi
}

# ---------------------------------------------------------------------------
# v6.39: کلاینت‌های CLI هوش مصنوعی (Claude Code + Grok CLI)
# همان الگوی 9router/OpenClaw: «تنظیمات می‌ماند، کد بازنصب می‌شود».
#   * تنظیمات کاربر : /root/.claude و /root/.grok و /etc/profile.d/ai-clients.sh
#                     → زیر /root و /etc هستند، پس در آرشیو حفظ می‌شوند.
#   * کد npm        : /usr/local/lib/node_modules/... → آرشیو نمی‌شود
#                     (حجیم و پر از node_modules) و اینجا بازنصب می‌شود.
# هر دو کلاینت به 9router محلی وصل‌اند، پس بدون 9router بی‌معنا هستند.
# ---------------------------------------------------------------------------
provision_ai_clients() {
  local pkg bin name
  for spec in "@anthropic-ai/claude-code:claude:Claude Code"; do
    pkg="${spec%%:*}"; rest="${spec#*:}"; bin="${rest%%:*}"; name="${rest#*:}"
    if command -v "$bin" >/dev/null 2>&1; then
      note "${name}: present — kept (Mode 2)"
      continue
    fi
    log "${name}: binary missing — reinstalling..."
    if ensure_npm && timeout 600 $SUDO env PATH="$PATH" npm install -g "$pkg" \
         --no-fund --no-audit >"${LOG_DIR}/${bin}.log" 2>&1; then
      note "${name}: REINSTALLED"
    else
      note "${name}: reinstall FAILED (non-fatal)"
      tail -10 "${LOG_DIR}/${bin}.log" 2>/dev/null | tee -a "${LOG_DIR}/summary.txt"
    fi
  done

  # --- Grok Build (xAI رسمی) ------------------------------------------------
  # نصب از x.ai/cli/install.sh (نه npm). باینری در /root/.grok/bin و symlink
  # در /usr/local/bin. کانفیگ /root/.grok/config.toml به 9router اشاره می‌کند
  # و چون models_base_url ست است، احراز هویت با API key انجام می‌شود و نیازی
  # به `grok login` یا اشتراک xAI نیست.
  # نکته: باینری ~۱۷۰MB است، پس مثل بقیهٔ کدها بازنصب می‌شود نه آرشیو.
  if command -v grok >/dev/null 2>&1 && [ -x /root/.grok/bin/grok ]; then
    note "Grok Build: present — kept (Mode 2)"
  else
    log "Grok Build: binary missing — reinstalling from x.ai..."
    if curl -fsSL --max-time 60 https://x.ai/cli/install.sh -o /tmp/grok-install.sh \
       && timeout 900 bash /tmp/grok-install.sh >"${LOG_DIR}/grok-build.log" 2>&1; then
      note "Grok Build: REINSTALLED ($(/root/.grok/bin/grok --version 2>/dev/null | head -1))"
    else
      note "Grok Build: reinstall FAILED (non-fatal)"
      tail -10 "${LOG_DIR}/grok-build.log" 2>/dev/null | tee -a "${LOG_DIR}/summary.txt"
    fi
  fi

  # اگر کانفیگ Grok Build گم شده بود (یا نصب تازه است) بازش بساز
  if [ -x /root/.grok/bin/grok ] && ! grep -q models_base_url /root/.grok/config.toml 2>/dev/null; then
    local gkey
    gkey=$(python3 -c "import json;print(json.load(open('/root/.openclaw/openclaw.json'))['models']['providers']['ninerouter']['apiKey'])" 2>/dev/null || true)
    if [ -n "$gkey" ]; then
      {
        printf '[cli]\ninstaller = "internal"\n\n[endpoints]\nmodels_base_url = "http://127.0.0.1:20128/v1"\n\n'
        printf '[models]\ndefault = "Agentic"\nallowed_models = ["Agentic", "Brain", "ox-alpha", "vps", "ultimate"]\n'
        for m in Agentic Brain ox-alpha vps ultimate; do
          printf '\n[model.%s]\nmodel = "%s"\nname = "%s (9router combo)"\napi_key = "%s"\napi_backend = "openai-completions"\n' \
                 "$m" "$m" "$m" "$gkey"
        done
      } > /root/.grok/config.toml
      chmod 600 /root/.grok/config.toml
      note "Grok Build: config.toml rebuilt (9router backend)"
    fi
  fi

  # اگر فایل env مشترک گم شده بود، از روی کلید 9router در کانفیگ OpenClaw بسازش
  if [ ! -f /etc/profile.d/ai-clients.sh ] && [ -f /root/.openclaw/openclaw.json ]; then
    local key
    key=$(python3 -c "import json;print(json.load(open('/root/.openclaw/openclaw.json'))['models']['providers']['ninerouter']['apiKey'])" 2>/dev/null || true)
    if [ -n "$key" ]; then
      $SUDO tee /etc/profile.d/ai-clients.sh >/dev/null <<PROF
export ANTHROPIC_BASE_URL=http://127.0.0.1:20128
export ANTHROPIC_AUTH_TOKEN=${key}
export ANTHROPIC_MODEL=Agentic
export CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT=1
export CLAUDE_CODE_MAX_CONTEXT_TOKENS=128000
export GROK_BASE_URL=http://127.0.0.1:20128/v1
export GROK_API_KEY=${key}
export GROK_MODEL=Agentic
export OPENAI_BASE_URL=http://127.0.0.1:20128/v1
export OPENAI_API_KEY=${key}
PROF
      $SUDO chmod 644 /etc/profile.d/ai-clients.sh
      note "ai-clients: /etc/profile.d/ai-clients.sh rebuilt"
    fi
  fi
}

provision_xui() {
  note "3x-ui: disabled by user — skip (Mode 2)"
}

provision_cloudflared() {
  local found=""
  for p in /usr/local/bin/cloudflared /usr/bin/cloudflared /root/.hermes/bin/cloudflared /root/cloudflared /opt/cloudflared "$RESTORE_ROOT/usr/local/bin/cloudflared" "$RESTORE_ROOT/root/.hermes/bin/cloudflared"; do
    if [ -x "$p" ]; then found="$p"; break; fi
  done
  if [ -n "$found" ]; then
    note "cloudflared: found at $found — ensured in /usr/local/bin"
    if [ "$found" != "/usr/local/bin/cloudflared" ]; then
      $SUDO cp -f "$found" /usr/local/bin/cloudflared 2>/dev/null || true
      $SUDO chmod +x /usr/local/bin/cloudflared 2>/dev/null || true
    fi
  else
    if has_hermes_data; then
      log "cloudflared: not found but hermes data exists (live or staged) — downloading (recovery)..."
      if curl -fsSL --max-time 60 https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /tmp/cloudflared; then
        $SUDO mv /tmp/cloudflared /usr/local/bin/cloudflared
        $SUDO chmod +x /usr/local/bin/cloudflared
        note "cloudflared: INSTALLED (recovery)"
      else
        note "cloudflared: download failed"
      fi
    else
      note "cloudflared: not found — skip"
    fi
  fi
}

log "=== provisioning start (Mode 2 + recovery v4.5.5 venv-valid check) ==="
provision_ai_clients
provision_9router
provision_openclaw
provision_hermes
provision_xui
provision_cloudflared
log "=== provisioning done ==="
echo ""
echo "----- PROVISION SUMMARY (Mode 2) -----"
cat "${LOG_DIR}/summary.txt"
echo "-----------------------------"
exit 0
