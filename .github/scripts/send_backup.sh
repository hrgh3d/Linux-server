#!/bin/bash
# send_backup.sh (hrgh3d) — بکاپ کامل + قابل‌بازگردانی روی حساب گیت‌هاب جدید
#   • بکاپ داده‌های سرور (کانفیگ‌ها، دیتابیس‌ها، پوشه‌های مهم)
#   • + بوت‌استرپ بازیابی: محتوای کل ریپو، کلید/توکن‌ها (Base64)، RECOVERY.md
#   • در حالت DR (هفتگی/دستی): اسنپ‌شات state هم بخش‌بخش ارسال می‌شود
# env: REPO, STATE_REPO, VPS_NAME, TARGET_IP, HAMID_PASSWORD, TAILSCALE_AUTH_KEY,
#      TELEGRAM_BOT_TOKEN, NOTIFY_CHAT_ID, STATE_TOKEN, PERSIST_TOKEN, DR_MODE,
#      + همهٔ سکرت‌های ریپو برای فایل بازیابی
set -uo pipefail

VPS_NAME="${VPS_NAME:-$(basename "${REPO:-vps}")}"
TS_HOSTNAME="${TS_HOSTNAME:-hrg-backup}"
LIMIT=$((45 * 1024 * 1024))
PART=$((40 * 1024 * 1024))
DR_MODE="${DR_MODE:-false}"
FORCE="${FORCE:-false}"
DEDUP_MIN="${DEDUP_MIN:-15}"
TRIGGER="${TRIGGER:-manual}"
API="https://api.github.com"
MARKER_PATH=".bundle-state.json"

echo "[backup] $(date -u +%FT%TZ) vps=${VPS_NAME} target=${TARGET_IP} dr=${DR_MODE} trigger=${TRIGGER} force=${FORCE}"

# ---------- v6.17: dedup — باندل تکراری داخل DEDUP_MIN دقیقه ارسال نمی‌شود ----------
# (مگر FORCE=true یا باندل قبلی DR نبوده و این یکی DR باشد — اسنپ‌شات state تازه‌تر لازم است)
MSHA=""
marker_fetch() {
  [ -n "${GITHUB_TOKEN:-}" ] || return 0
  local r
  r="$(curl -sS -m 20 -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" \
       "${API}/repos/${REPO}/contents/${MARKER_PATH}?ref=main" 2>/dev/null)"
  MSHA="$(printf '%s' "$r" | jq -r '.sha // ""' 2>/dev/null)"
  MARK_TS="$(printf '%s' "$r" | jq -r '.content // ""' 2>/dev/null | tr -d '\n' | base64 -d 2>/dev/null | jq -r '.ts // ""' 2>/dev/null)"
  MARK_DR="$(printf '%s' "$r" | jq -r '.content // ""' 2>/dev/null | tr -d '\n' | base64 -d 2>/dev/null | jq -r '.dr // false' 2>/dev/null)"
}
marker_write() { # $1=bytes
  [ -n "${GITHUB_TOKEN:-}" ] || return 0
  MSHA="$MSHA" DRFLAG="$DR_MODE" TRG="$TRIGGER" python3 - "$1" > /tmp/bm-body.json <<'PY'
import base64, json, os, sys, time
raw = json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "trigger": os.environ.get("TRG",""),
                  "dr": os.environ.get("DRFLAG") == "true", "bytes": int(sys.argv[1] or 0)}).encode()
body = {"message": "backup-bundle: " + os.environ.get("TRG", ""), "content": base64.b64encode(raw).decode(), "branch": "main"}
if os.environ.get("MSHA"): body["sha"] = os.environ["MSHA"]
print(json.dumps(body))
PY
  curl -sS -m 20 -X PUT -H "Authorization: Bearer ${GITHUB_TOKEN}" -H 'Content-Type: application/json' \
    -d @/tmp/bm-body.json "${API}/repos/${REPO}/contents/${MARKER_PATH}" -o /dev/null -w '[backup] marker write http=%{http_code}\n'
}
marker_fetch
if [ "$FORCE" != "true" ] && [ -n "${MARK_TS:-}" ]; then
  AGE_MIN=$(( ( $(date -u +%s) - $(date -u -d "$MARK_TS" +%s 2>/dev/null || echo 0) ) / 60 ))
  if [ "$AGE_MIN" -lt "$DEDUP_MIN" ]; then
    if [ "${MARK_DR:-false}" = "true" ] || [ "$DR_MODE" != "true" ]; then
      echo "[backup] bundle sent ${AGE_MIN}min ago (dr=${MARK_DR:-?}, dedup=${DEDUP_MIN}min) and FORCE!=true — skipping"
      exit 0
    fi
    echo "[backup] recent bundle was non-DR; this is DR — continuing"
  fi
fi

# ---------- ۰) بوت‌استرپ بازیابی (روی runner) ----------
BK=/tmp/bootstrap; rm -rf "$BK"; mkdir -p "$BK/recovery"
if git rev-parse --git-dir >/dev/null 2>&1; then
  git archive --format=tar.gz -o "$BK/repo.tar.gz" HEAD 2>/dev/null && echo "[backup] repo bundle OK ($(stat -c%s "$BK/repo.tar.gz") bytes)"
fi
if [ -f .github/recovery/RECOVERY.md ]; then cp .github/recovery/RECOVERY.md "$BK/recovery/RECOVERY.md"; fi
{
  echo "# کلیدهای بازیابی — مقادیر Base64 هستند. برای دیدن مقدار: base64 -d <<< '<مقدار>'"
  echo "# این‌ها را به‌عنوان سکرت ریپوی جدید ثبت کن (نام‌ها همان‌ها). تاریخ: $(date -u +%FT%TZ)"
  for n in HAMID_PASSWORD PERSIST_TOKEN STATE_TOKEN SUCCESSOR_TOKEN TAILSCALE_AUTH_KEY \
           TAILSCALE_API_TOKEN TAILSCALE_FIXED_IP TELEGRAM_BOT_TOKEN REPORT_BOT_TOKEN NOTIFY_CHAT_ID \
           MIRZABOT_TOKEN MIRZABOT_ADMIN_ID MIRZABOT_ADMIN_USER MIRZABOT_BOT_NAME MIRZABOT_BRAND \
           XUI_RESET_USER XUI_RESET_PASS DASHBOARD_PASSWORD; do
    v="$(eval "printf '%s' \"\${$n:-}\"")"
    [ -n "$v" ] && printf '%s=%s\n' "$n" "$(printf '%s' "$v" | base64 -w0)"
  done
} > "$BK/recovery/secrets.env"
echo "[backup] recovery keys: $(grep -c '=' "$BK/recovery/secrets.env") مورد"
{
  echo "vps=$VPS_NAME"; echo "time=$(date -u +%FT%TZ)"; echo "repo=$REPO"; echo "state_repo=$STATE_REPO"
  echo "files:"; ls -l "$BK" "$BK/recovery" 2>/dev/null | awk '{print "  "$9" "$5}'
} > "$BK/manifest.txt"

# ---------- ۱) بکاپ سرور (روی سرور hrgh3d) ----------
sudo apt-get update -qq >/dev/null 2>&1 || true
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o DPkg::Lock::Timeout=120 \
  curl jq sshpass openssh-client ca-certificates >/dev/null 2>&1 || true

if [ -n "${TAILSCALE_AUTH_KEY:-}" ] && ! tailscale status >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1 || true
  sudo tailscale up --authkey="${TAILSCALE_AUTH_KEY}" --hostname="${TS_HOSTNAME}" --accept-routes --ssh=false \
    >/tmp/tsup.log 2>&1 || { echo "[backup] tailscale up failed"; tail -5 /tmp/tsup.log; }
  for _ in $(seq 1 20); do sudo tailscale status --json 2>/dev/null | jq -e '.Self.Online==true' >/dev/null 2>&1 && break || sleep 2; done
fi

SSHOPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/known_hosts -o PreferredAuthentications=password \
         -o PubkeyAuthentication=no -o ConnectTimeout=15 -o ServerAliveInterval=15)
SSHRUN() { sshpass -p "${ROOT_PASS}" ssh "${SSHOPTS[@]}" root@"${TARGET_IP}" "$@"; }
ROOT_PASS="${HAMID_PASSWORD:?HAMID_PASSWORD تنظیم نشده است}"
SSH_OK=0
for attempt in $(seq 1 12); do
  if SSHRUN 'echo OK' 2>/dev/null | grep -q OK; then SSH_OK=1; break; fi
  echo "[backup] waiting ssh ($attempt)"; sleep 6
done
if [ "$SSH_OK" != "1" ]; then
  echo "[backup] SSH FAILED"
  if [ "$DR_MODE" = "true" ]; then
    # v6.17: در حالت DR (رویداد قطع/وصل یا دستی full) حتی بدون سرور هم باندل می‌فرستیم:
    # bootstrap (ریپو+کلیدها+RECOVERY) + اسنپ‌شات state از ریپوی state.
    echo "[backup] DR mode → continuing WITHOUT server data"
  else
    curl -fsS -m 20 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${NOTIFY_CHAT_ID}" --data-urlencode "text=سیستم ${VPS_NAME} قطع شد ❌
(بکاپ نگرفت: ورود SSH برقرار نشد)" >/dev/null 2>&1 || true
    exit 1
  fi
fi
echo "[backup] ssh auth OK (single secret: HAMID_PASSWORD)"
if [ "$SSH_OK" != "1" ]; then
  M=/tmp/merge; rm -rf "$M"; mkdir -p "$M"
  cp -r "$BK" "$M/bootstrap"
  echo "server-data: UNAVAILABLE (ssh failed at $(date -u +%FT%TZ)) — bundle = bootstrap + state snapshot" > "$M/SERVER-DATA-UNAVAILABLE.txt"
  tar -czf /tmp/final-backup.tar.gz -C "$M" .
  LOCAL_SIZE=$(stat -c%s /tmp/final-backup.tar.gz)
  echo "[backup] bootstrap-only bundle size = ${LOCAL_SIZE} bytes"
else
SSH() { SSHRUN "$@"; }

SSH 'cat > /tmp/bkbuild.sh' <<'REMOTE'
set -u
B=/tmp/bkbuild; rm -rf "$B"; mkdir -p "$B"
MAN="$B/manifest.txt"; : > "$MAN"
add() { printf '  %s\n' "$1" >> "$MAN"; }
BUDGET=$((36000 * 1024))
total=0

# v6.35 — مسیرهایی که هرگز نباید در باندل بیایند: بازساختنی‌اند ولی حجیم‌اند و
# باعث می‌شدند کل /root از بودجه رد شود و SKIP بخورد (یعنی کانفیگ OpenClaw و
# دستگاه‌های جفت‌شده اصلاً بکاپ نمی‌شدند).
EXCL=(
  --exclude=./root/.openclaw/cache      --exclude=root/.openclaw/cache
  --exclude=./root/.openclaw/tmp        --exclude=root/.openclaw/tmp
  --exclude=./root/.openclaw/media      --exclude=root/.openclaw/media
  --exclude=./root/.npm                 --exclude=root/.npm
  --exclude=./root/.cache               --exclude=root/.cache
  --exclude=./root/.9router/logs        --exclude=root/.9router/logs
  --exclude=*/node_modules              --exclude=*/__pycache__
  --exclude=*.sock                      --exclude=*.pid
  # آرشیوهای نجات/بکاپ قبلی داخل /root — خودشان بکاپ‌اند، نباید تودرتو بیایند
  --exclude=./root/*.tar.gz             --exclude=root/*.tar.gz
  --exclude=./root/hermes-rescue-*      --exclude=root/hermes-rescue-*
  --exclude=./root/hermes-pre-update-keep --exclude=root/hermes-pre-update-keep
  --exclude=*/\.git/objects
)

# v6.35.1 — اول فشرده کن، بعد تصمیم بگیر.
# تخمین قبلی بر پایهٔ `du` (حجم خام) بود، ولی این فایل‌ها ۱۰ تا ۲۰ برابر فشرده
# می‌شوند. نتیجه: app-code/bin-scripts/home-root با «حجم زیاد» رد می‌شدند در
# حالی که کل باندل فقط ۲.۳MB از بودجهٔ ۳۶MB را پر کرده بود. حالا tar ساخته
# می‌شود و اندازهٔ *واقعی* سنجیده می‌شود؛ اگر از بودجه رد شد حذفش می‌کنیم.
try_tar() {
  out="$B/$1"; name="$1"; shift
  have=0
  for p in "$@"; do [ -e "$p" ] && have=1; done
  [ "$have" = "1" ] || { add "SKIP $name (مسیری وجود ندارد)"; return 0; }
  tar -czf "$out" --ignore-failed-read "${EXCL[@]}" "$@" 2>/dev/null
  [ -s "$out" ] || { add "SKIP $name (خالی)"; rm -f "$out"; return 0; }
  sz=$(stat -c%s "$out")
  if [ "$((total + sz))" -gt "$BUDGET" ]; then
    add "SKIP $name (بودجه پر شد: $((sz/1024))KB فشرده)"
    rm -f "$out"
    return 0
  fi
  total=$((total + sz))
  add "$name ($(du -h "$out" | cut -f1))"
}

# v6.35: دیتابیس‌های زندهٔ sqlite را با VACUUM INTO می‌گیریم تا torn نباشند.
# مهم‌ترینش /root/.openclaw/state/openclaw.sqlite است: جدول دستگاه‌های
# جفت‌شده. بدون آن، بعد از بازیابی باید همهٔ گوشی‌ها دوباره pair شوند.
snap_sqlite() {
  local src="$1" dst="$B/sqlite/$2"
  [ -f "$src" ] || return 0
  mkdir -p "$B/sqlite"
  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "$src" "VACUUM INTO '$dst'" 2>/dev/null || cp -f "$src" "$dst" 2>/dev/null
  else
    cp -f "$src" "$dst" 2>/dev/null
  fi
  [ -s "$dst" ] && add "sqlite/$2 ($(du -h "$dst" | cut -f1))"
}
if [ -f /etc/x-ui/x-ui.db ]; then
  if sqlite3 /etc/x-ui/x-ui.db "VACUUM INTO '$B/x-ui.db'" 2>/dev/null || cp -f /etc/x-ui/x-ui.db "$B/x-ui.db" 2>/dev/null; then
    total=$((total + $(stat -c%s "$B/x-ui.db"))); add "x-ui.db ($(du -h "$B/x-ui.db" | cut -f1))"
  fi
fi
if command -v mysqldump >/dev/null 2>&1; then
  if mysqldump --single-transaction --all-databases 2>/dev/null | gzip -6 > "$B/mysql-all.sql.gz"; then
    [ -s "$B/mysql-all.sql.gz" ] && { total=$((total + $(stat -c%s "$B/mysql-all.sql.gz"))); add "mysql-all.sql.gz ($(du -h "$B/mysql-all.sql.gz" | cut -f1))"; }
  else
    add "SKIP mysql (دسترسی نبود)"
  fi
fi
# --- v6.35: اسنپ‌شات دیتابیس‌های زنده قبل از tar ---
snap_sqlite /root/.openclaw/state/openclaw.sqlite openclaw-state.sqlite
snap_sqlite /root/.9router/db/data.sqlite 9router-data.sqlite

# v6.35.1 — ترتیب بر اساس بحرانی بودن: اگر روزی بودجه پر شد، چیزهای
# غیرقابل‌بازسازی باید از قبل داخل باندل باشند.
# ۱) هویت گره تیل‌اسکیل + مسیر ماندگار Serve. بدون آن، بعد از بازیابی آدرس
#    MagicDNS عوض می‌شود و همهٔ setup codeها و لینک داشبورد باطل می‌شوند.
try_tar tailscale-state.tar.gz /var/lib/tailscale
# ۲) کانفیگ/سشن OpenClaw (منهای cache/tmp/media)
try_tar openclaw.tar.gz /root/.openclaw
# ۳) یونیت‌ها و کانفیگ سرویس‌ها (system + user برای hermes)
try_tar services.tar.gz /etc/nginx /etc/cron.d /etc/systemd/system /etc/systemd/user
# ۴) همهٔ نگهبان‌ها و اسکریپت‌های عملیاتی
try_tar bin-scripts.tar.gz /usr/local/bin /usr/local/sbin
# ۵) کد و دادهٔ اپ‌ها
try_tar app-code.tar.gz /opt/9router /root/9router /opt/hermes /root/.hermes /var/www
# ۶) باقی /root به‌عنوان تور ایمنی
try_tar home-root.tar.gz /root
{
  echo "host: $(hostname)"; echo "date: $(date -u +%FT%TZ)"; echo "uptime: $(uptime -p 2>/dev/null)"
  echo "--- running services ---"; systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '{print $1}' | head -25
  echo "--- disk ---"; df -h / | tail -1
  echo "--- tailscale ---"; tailscale ip -4 2>/dev/null | head -2
  tailscale status --json 2>/dev/null | python3 -c "
import sys,json
try: print('  magicdns:', json.load(sys.stdin).get('Self',{}).get('DNSName','').rstrip('.'))
except Exception: pass" 2>/dev/null
  echo "--- tailscale serve ---"; tailscale serve status 2>/dev/null | head -4
  echo "--- openclaw ---"
  /usr/local/bin/openclaw --version 2>/dev/null | head -1
  /usr/local/bin/openclaw devices list 2>/dev/null | grep -E "^ +[0-9a-f]{16}" | head -5
  echo "--- versions ---"
  echo "  node(system): $(node -v 2>/dev/null)"
  echo "  node(openclaw): $(/opt/openclaw-node/bin/node -v 2>/dev/null)"
  echo "  hermes: $(/root/.hermes/bin/hermes --version 2>/dev/null | head -1)"
  echo "--- manifest ---"; cat "$MAN" 2>/dev/null
} > "$B/info.txt" 2>/dev/null
OUT=/tmp/$(hostname)-backup-$(date -u +%Y%m%d-%H%M).tar.gz
tar -czf "$OUT" -C "$B" .
rm -rf "$B"
echo "BACKUP_FILE=$OUT"
stat -c 'SIZE=%s' "$OUT"
REMOTE

RES="$(SSH 'bash /tmp/bkbuild.sh 2>&1 | tail -6')"
echo "[backup] remote: $(printf '%s' "$RES" | tr '\n' ' ')"
OUT="$(printf '%s' "$RES" | sed -n 's/^BACKUP_FILE=//p' | tail -1)"
[ -n "$OUT" ] || { echo "[backup] build failed"; exit 1; }

sshpass -p "${ROOT_PASS}" scp "${SSHOPTS[@]}" "root@${TARGET_IP}:${OUT}" /tmp/server-backup.tar.gz >/dev/null 2>&1 \
  || { echo "[backup] scp failed"; exit 1; }
SSH "rm -f ${OUT} /tmp/bkbuild.sh" >/dev/null 2>&1 || true

# ---------- ۲) ادغام: بکاپ سرور + بوت‌استرپ ----------
M=/tmp/merge; rm -rf "$M"; mkdir -p "$M"
tar -xzf /tmp/server-backup.tar.gz -C "$M" 2>/dev/null || true
cp -r "$BK" "$M/bootstrap"
{ echo "== محتویات =="; echo "server files:"; ls -1 "$M" | sed 's/^/  /';
  echo "bootstrap:"; ls -1 "$M/bootstrap" "$M/bootstrap/recovery" 2>/dev/null | sed 's/^/  /'; } >> "$M/bootstrap/manifest.txt"
tar -czf /tmp/final-backup.tar.gz -C "$M" .
LOCAL_SIZE=$(stat -c%s /tmp/final-backup.tar.gz)
echo "[backup] final bundle size = ${LOCAL_SIZE} bytes"
fi

# ---------- v6.35: راستی‌آزمایی باندل قبل از ارسال ----------
# باندلی که ناقص باشد بدتر از نبودنش است، چون کاذب اطمینان می‌دهد. پس قبل از
# ارسال، محتویات را بازرسی می‌کنیم و نتیجه را در کپشن تلگرام می‌نویسیم.
VERDICT=""
verify_bundle() {
  local f="$1" list missing=0 crit ok
  list=$(tar -tzf "$f" 2>/dev/null)
  [ -n "$list" ] || { VERDICT="❌ باندل قابل خواندن نیست"; return 1; }
  for crit in bootstrap/repo.tar.gz bootstrap/recovery/secrets.env bootstrap/recovery/RECOVERY.md; do
    printf '%s\n' "$list" | grep -q "$crit" || { echo "[verify] MISSING $crit"; missing=$((missing+1)); }
  done
  if printf '%s\n' "$list" | grep -q "SERVER-DATA-UNAVAILABLE"; then
    VERDICT="⚠️ بدون دادهٔ سرور (SSH قطع بود) — bootstrap + state"
    return 0
  fi
  for crit in tailscale-state.tar.gz openclaw.tar.gz sqlite/openclaw-state.sqlite \
              app-code.tar.gz services.tar.gz bin-scripts.tar.gz home-root.tar.gz; do
    printf '%s\n' "$list" | grep -q "$crit" || { echo "[verify] MISSING $crit"; missing=$((missing+1)); }
  done
  ok=$(printf '%s\n' "$list" | grep -c 'tar.gz\|sqlite')
  if [ "$missing" -eq 0 ]; then
    VERDICT="✅ کامل — $ok جزء، همهٔ موارد بحرانی حاضر"
  else
    VERDICT="⚠️ ناقص — $missing جزء بحرانی غایب است"
  fi
  echo "[verify] members=$ok missing=$missing"
  return 0
}
verify_bundle /tmp/final-backup.tar.gz

send_doc() {
  curl -fsS -m 300 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
    -F "chat_id=${NOTIFY_CHAT_ID}" -F "document=@$1" -F "caption=$2" >/dev/null 2>&1
}
CAP="🗄 بکاپ کامل سیستم ${VPS_NAME} — $(date -u '+%Y-%m-%d %H:%M') UTC (رویداد: ${TRIGGER})
شامل: دادهٔ سرور + هویت Tailscale + OpenClaw (کانفیگ و دستگاه‌های جفت‌شده) + کل ریپو + کلیدها + RECOVERY.md
بازرسی: ${VERDICT}
بازگردانی: RECOVERY.md بخش ۵ را دنبال کن (روی سرور خالی هم کار می‌کند)"
if [ "$LOCAL_SIZE" -le "$LIMIT" ]; then
  send_doc /tmp/final-backup.tar.gz "${CAP}" && echo "[backup] sent to telegram" || echo "[backup] WARN: telegram send failed"
else
  split -b "$PART" -d -a 2 /tmp/final-backup.tar.gz /tmp/bk-part-
  n=$(ls /tmp/bk-part-* | wc -l); i=0
  for f in /tmp/bk-part-*; do i=$((i+1)); send_doc "$f" "${CAP} — بخش ${i}/${n}" && echo "[backup] part ${i}/${n} sent" || echo "[backup] WARN: part ${i} failed"; done
fi

# ---------- ۳) حالت DR: ارسال اسنپ‌شات state ----------
if [ "$DR_MODE" = "true" ]; then
  echo "[backup] DR mode: downloading state snapshot"
  TOKX="${STATE_TOKEN:-${PERSIST_TOKEN:-}}"
  if [ -n "$TOKX" ] && [ -n "${STATE_REPO:-}" ]; then
    ASSET_URL=$(curl -sS -m 60 -H "Authorization: token ${TOKX}" -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${STATE_REPO}/releases/tags/state" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); a=sorted([x for x in d.get("assets",[]) if x["name"].startswith("state-") and x["name"].endswith(".tar.gz")], key=lambda x:x["updated_at"]); print(a[-1]["url"] if a else "")' 2>/dev/null)  # v6.17 FIX: فقط state-*.tar.gz — قبلاً heartbeat (۷۶ بایت!) به‌جای اسنپ‌شات انتخاب می‌شد
    if [ -n "$ASSET_URL" ]; then
      curl -sSL -m 900 -H "Authorization: token ${TOKX}" -H "Accept: application/octet-stream" "$ASSET_URL" -o /tmp/state.tar.gz \
        && { STATE_SIZE=$(stat -c%s /tmp/state.tar.gz); echo "[backup] state size=${STATE_SIZE}"; }
      if [ -s /tmp/state.tar.gz ]; then
        split -b "$PART" -d -a 2 /tmp/state.tar.gz /tmp/state.part-
        n=$(ls /tmp/state.part-* | wc -l); i=0
        for f in /tmp/state.part-*; do
          i=$((i+1))
          send_doc "$f" "🧩 اسنپ‌شات state سیستم ${VPS_NAME} — بخش ${i}/${n} (${n} بخش؛ برای استفاده: cat state.part-* > state.tar.gz)" \
            && echo "[backup] state part ${i}/${n} sent" || echo "[backup] WARN: state part ${i} failed"
        done
      fi
    else
      echo "[backup] WARN: state asset not found"
    fi
  else
    echo "[backup] WARN: no token/state repo for DR"
  fi
fi
marker_write "$(( ${LOCAL_SIZE:-0} + ${STATE_SIZE:-0} ))"
echo "[backup] done"
