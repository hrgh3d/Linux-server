#!/bin/bash
# ============================================================================
# save.sh (v5.1) — اسنپ‌شات «داده/تنظیمات کاربر» + کاتالوگ پکیج‌ها (نسخه‌دار)
#
#   payload  = فقط Configuration/Data در ریشه‌های persist.list (payload.py)
#              فایل‌های نصب پکیج‌ها (node_modules/venv/binary/…) شامل نیستند.
#   catalog  = installed.json با نسخهٔ دقیق پکیج‌ها (apt name=ver / npm name@ver
#              / pip name==ver) تا در Restore همان نسخه نصب شود.
#   sqlite   = دیتابیس‌های SQLite زنده (x-ui/9router/…) قبل از آرشیو با
#              sqlite_stage.py به‌صورت Consistent اسنپ‌شات می‌شوند و -wal/-shm
#              وارد آرشیو نمی‌شوند.
#   validate = آرشیو پیش از آپلود کامل بررسی می‌شود (سلامت، شمار اعضا، حضور
#              installed.json، نبودِ موارد excludeشده)؛ اگر تأیید نشود آپلود
#              انجام نمی‌شود و State سالم قبلی دست‌نخورده می‌ماند.
#   آرشیو    = _meta/… + درخت payload؛ آپلود rolling تک‌نسخه‌ای (skip بی‌تغییر).
# ============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/common.sh"

# اجرای سریالی بدون skip خاموش: اگر save دیگری در حال اجراست منتظر می‌مانیم
# (نه اینکه بی‌صدا «skip» بگوییم و بعداً نتیجهٔ OK دروغین چاپ شود).
LOCK=/tmp/persist-save.lock
exec 9>"$LOCK"
if ! flock -w 900 9; then
  log "ERROR: could not acquire save lock within 900s — another save stuck?"
  exit 1
fi

META=/tmp/persist-meta
LIST=/tmp/payload.list
LIST_FINAL=/tmp/payload.list.final
SNAP_LIST=/tmp/sqlite-snap.list
SNAP_DIR=/tmp/persist-sqlite
STATS=/tmp/payload.stats.json
MEMBERS=/tmp/state.members
sudo rm -rf "$META" "$SNAP_DIR"
mkdir -p "$META/_meta" "$SNAP_DIR"
rm -f "$LIST" "$LIST_FINAL" "$SNAP_LIST" "$STATS" "$MEMBERS" /tmp/state.tar.gz

T0=$(date +%s)
phase() { echo "[persist $(date -u '+%T') +$(( $(date +%s) - T0 ))s] $*"; }
log "Starting v5.1 payload snapshot..."

fatal() {
  log "ERROR: $*"
  sudo rm -rf "$META" "$SNAP_DIR" 2>/dev/null || true
  sudo rm -f /tmp/state.tar.gz 2>/dev/null || true
  exit 1
}

# ----------------------------------------------------------- 1) package data
if command -v dpkg >/dev/null 2>&1; then
  timeout 90 dpkg --get-selections > "$META/_meta/packages.list" 2>/dev/null || true
  timeout 60 dpkg-query -W -f='${Package}\t${Version}\n' 2>/dev/null \
    > /tmp/apt-version.map || true
fi
if command -v apt-mark >/dev/null 2>&1; then
  timeout 60 apt-mark showmanual > "$META/_meta/manual_packages.list" 2>/dev/null || true
fi

# npm: نقشهٔ نام->نسخه + لیست نام‌ها
NPM_VERSION_MAP=/tmp/npm-version.map
: > "$NPM_VERSION_MAP"; : > "$META/_meta/npm.cur.txt"
if command -v npm >/dev/null 2>&1; then
  timeout 60 npm ls -g --depth=0 --json 2>/dev/null \
    | jq -r '.dependencies | to_entries[] | [.key, (.value.version // "")] | @tsv' \
    2>/dev/null | sort > "$NPM_VERSION_MAP" || true
  cut -f1 "$NPM_VERSION_MAP" 2>/dev/null | sort > "$META/_meta/npm.cur.txt" || true
fi

# pip: خطوط کامل freeze (name==version) + لیست نام‌ها
PIP_FREEZE=/tmp/pip-freeze.lines
: > "$PIP_FREEZE"; : > /tmp/pip-cur-names.list
if command -v pip3 >/dev/null 2>&1; then
  timeout 60 pip3 list --format=freeze 2>/dev/null \
    | grep -E '^[A-Za-z0-9_.-]+==[A-Za-z0-9.+\-]+$' > "$PIP_FREEZE" || true
  sed 's/==.*//' "$PIP_FREEZE" 2>/dev/null | sort > /tmp/pip-cur-names.list || true
fi

# ساخت installed.json با نسخهٔ دقیق (apt=, npm@, pip==)
python3 - "$META/_meta" /tmp <<'PY'
import datetime, json, os, sys
meta, tmp = sys.argv[1], sys.argv[2]
def read(p):
    if os.path.exists(p):
        with open(p, encoding="utf-8", errors="replace") as fh:
            return [l.strip() for l in fh if l.strip()]
    return []
def readmap(p):
    m = {}
    for l in read(p):
        if "\t" in l:
            k, v = l.split("\t", 1)
            m[k.strip()] = v.strip()
    return m

manual   = read(os.path.join(meta, "manual_packages.list"))
base_man = set(read(os.path.join(tmp, "base_manual_packages.list")))
# پکیج‌های apt کاربر = manual فعلی منهای پایهٔ image منهای tailscale (اختصاصی)
user_apt = sorted(p for p in manual
                  if p not in base_man and p not in ("tailscale", "tailscale-archive-keyring"))
apt_map  = readmap(os.path.join(tmp, "apt-version.map"))
apt = [f"{p}={apt_map[p]}" if p in apt_map and apt_map[p] else p for p in user_apt]

npm_map    = readmap(os.path.join(tmp, "npm-version.map"))
base_npm   = set(read(os.path.join(tmp, "base_npm.list")))
user_npm_n = sorted(n for n in npm_map if n not in base_npm)
npm  = [f"{n}@{npm_map[n]}" if npm_map.get(n) else n for n in user_npm_n]

pip_map    = {}
for line in read(os.path.join(tmp, "pip-freeze.lines")):
    if "==" in line:
        k, _ = line.split("==", 1)
        pip_map.setdefault(k.strip(), []).append(line.strip())
base_pip   = set(read(os.path.join(tmp, "base_pip.list")))
user_pip_n = sorted(k for k in pip_map if k not in base_pip)
pip  = [pip_map[k][0] if pip_map.get(k) else k for k in user_pip_n]

with open(os.path.join(meta, "user_packages.list"), "w") as fh:
    fh.write("\n".join(user_apt) + ("\n" if user_apt else ""))
with open(os.path.join(meta, "user_npm.list"), "w") as fh:
    fh.write("\n".join(user_npm_n) + ("\n" if user_npm_n else ""))
with open(os.path.join(meta, "user_pip.list"), "w") as fh:
    fh.write("\n".join(user_pip_n) + ("\n" if user_pip_n else ""))

catalog = {
    "schema": "v6",
    "note": "apt='name=ver' npm='name@ver' pip='name==ver'; old plain-name entries also supported",
    "apt": apt,
    "npm": npm,
    "pip": pip,
}
catalog["meta"] = {
    "run_id": os.environ.get("GITHUB_RUN_ID", "local"),
    "boot_ts": os.environ.get("BOOT_TS", ""),
    "saved_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
with open(os.path.join(meta, "installed.json"), "w") as fh:
    json.dump(catalog, fh, indent=2)
print("[persist] catalog: apt=%d npm=%d pip=%d" % (len(apt), len(npm), len(pip)))
PY
RC=$?
[ $RC -eq 0 ] || fatal "catalog build failed (rc=$RC)"

# ----------------------------------------------------------- 2) markers
RUN_INFO="run_id=${GITHUB_RUN_ID:-local} run_attempt=${GITHUB_RUN_ATTEMPT:-1} boot_ts=${BOOT_TS:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
for marker in /root/persist-marker.txt /home/Hamid/persist-marker.txt; do
  d="${marker%/*}"
  [ -d "$d" ] || continue
  if [ ! -f "$marker" ] || ! grep -q "run_id=${GITHUB_RUN_ID:-local}" "$marker" 2>/dev/null; then
    echo "$RUN_INFO saved_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" | tee "$marker" >/dev/null 2>&1 || true
    [ "$d" = "/home/Hamid" ] && chown Hamid:Hamid "$marker" 2>/dev/null || true
  fi
done

# ----------------------------------------------------------- 3) payload list
phase "scanning payload roots..."
python3 "$SCRIPT_DIR/payload.py" list --roots "$SCRIPT_DIR/persist.list" \
  --out "$LIST" --base /tmp --stats "$STATS" \
  --keepbig "$SCRIPT_DIR/payload_keepbig.list"
RC=$?
if [ $RC -ne 0 ] || [ ! -s "$LIST" ]; then
  fatal "payload scan failed"
fi
cat "$STATS" 2>/dev/null | jq -c '{dirs,files,links,mb,top:.["top"],top2:.["top2"],big:.["big"],skipped_big:.["skipped_big"],skipped_big_total_bytes:.["skipped_big_total_bytes"]}' | sed 's/^/[persist] stats /' || true
if [ -s "$STATS" ]; then
  SKIPB=$(jq -r '."skipped_big_total_bytes"' "$STATS" 2>/dev/null || echo 0)
  if [ "$SKIPB" != "0" ] && [ -n "$SKIPB" ]; then
    log "NOTE: ${SKIPB} bytes of >cap files excluded (see WARN big-file-skip above / payload_keepbig.list)"
  fi
fi

# ----------------------------------------------------------- 4) sqlite stage
# دیتابیس‌های SQLite زنده را به‌صورت Consistent کپی می‌کنیم تا آرشیو هرگز فایل
# دیتابیسِ درحال‌نوشتن را نخواند؛ -wal/-shm هم در payload.py پرون می‌شوند.
phase "staging consistent SQLite snapshots..."
python3 "$SCRIPT_DIR/sqlite_stage.py" "$LIST" "$SNAP_DIR" "$LIST_FINAL" "$SNAP_LIST" --fallback \
  || fatal "sqlite staging failed (cannot guarantee consistent db snapshot)"

# ----------------------------------------------------------- 5) tar
PAYLOAD_N=$(wc -l < "$LIST" 2>/dev/null || echo 0)
META_FILES=()
for _f in "$META"/_meta/*; do [ -e "$_f" ] && META_FILES+=("${_f#"$META"/}"); done
META_N=${#META_FILES[@]}
EXPECTED=$(( PAYLOAD_N + META_N ))

# ---- v6.10: خارج‌سازی secret از آرشیو ---------------------------------------
# TELEGRAM_BOT_TOKEN هرگز در آرشیو state ذخیره نمی‌شود: قبل از tar خط آن در
# فایل زنده خالی می‌شود و بلافاصله بعد از tar برمی‌گردد (trap: حتی در خطا).
# تزریق مقدار واقعی در هر بوت توسط secrets_inject.sh انجام می‌شود.
TS_ENV=/root/.hermes/.env
ENV_BACKUP=""
if [ -f "$TS_ENV" ] && grep -q '^TELEGRAM_BOT_TOKEN=.\{4,\}' "$TS_ENV" 2>/dev/null; then
  ENV_BACKUP="/tmp/.ts-env.keep.$$"
  cp -p "$TS_ENV" "$ENV_BACKUP"
  sed -i 's/^TELEGRAM_BOT_TOKEN=.*/TELEGRAM_BOT_TOKEN=/' "$TS_ENV"
  log "secret: TELEGRAM_BOT_TOKEN blanked for archive (restored after tar)"
fi
restore_env_secret() {
  if [ -n "$ENV_BACKUP" ] && [ -f "$ENV_BACKUP" ]; then
    cp -p "$ENV_BACKUP" "$TS_ENV" 2>/dev/null || true
    rm -f "$ENV_BACKUP"
    log "secret: live .env restored after tar"
  fi
}
trap 'restore_env_secret' EXIT

phase "creating archive..."
V=""; [ -n "${TAR_VERBOSE:-}" ] && V="-v"
set +e
# NOTE: --no-recursion MUST be a global option (before the -T member lists).
timeout 300 sudo tar -c $V -f /tmp/state.tar.gz \
  --no-recursion --use-compress-program='gzip -1' \
  -C / -T "$LIST_FINAL" \
  -C "$SNAP_DIR" -T "$SNAP_LIST" \
  -C "$META" "${META_FILES[@]}" \
  >/tmp/tar.log 2>&1
RC=$?
set -e
if [ $RC -ne 0 ]; then
  log "ERROR: tar failed/timed out (rc=$RC). Last files processed:"
  tail -15 /tmp/tar.log 2>/dev/null | sed 's/^/    /'
  fatal "tar failed (rc=$RC)"
fi
SIZE=$(stat -c%s /tmp/state.tar.gz 2>/dev/null || echo 0)
SIZEH=$(du -h /tmp/state.tar.gz | cut -f1)
DIGEST=$(sha256sum /tmp/state.tar.gz | cut -d' ' -f1)
phase "archive created: ${SIZEH} (${SIZE} bytes) sha256=${DIGEST:0:16}"

# ----------------------------------------------------------- 6) validate (pre-upload)
phase "validating archive before upload..."
VALIDATE_FAIL=0
# 6a) gzip + tar readable
if ! gzip -t /tmp/state.tar.gz 2>/dev/null; then
  log "ERROR: archive fails gzip integrity test"; VALIDATE_FAIL=1
fi
if [ $VALIDATE_FAIL -eq 0 ] && ! timeout 120 tar -tzf /tmp/state.tar.gz > "$MEMBERS" 2>/dev/null; then
  log "ERROR: archive cannot be listed with tar -tzf"; VALIDATE_FAIL=1
fi
if [ $VALIDATE_FAIL -eq 0 ]; then
  # 6b) member count vs expected (payload list + _meta files)
  ACTUAL=$(grep -cvE '^_meta/?$' "$MEMBERS" 2>/dev/null || true)
  if [ "${ACTUAL:-0}" -ne "$EXPECTED" ]; then
    log "ERROR: member count mismatch — expected=${EXPECTED} actual=${ACTUAL}"
    VALIDATE_FAIL=1
  fi
  # 6c) installed.json really inside
  if ! grep -qx '_meta/installed.json' "$MEMBERS" 2>/dev/null; then
    log "ERROR: _meta/installed.json missing from archive"; VALIDATE_FAIL=1
  fi
  # 6d) no pruned/forbidden content inside
  if ! python3 "$SCRIPT_DIR/payload.py" validate --members "$MEMBERS" >/tmp/validate.log 2>&1; then
    log "ERROR: forbidden content found in archive:"
    tail -20 /tmp/validate.log | sed 's/^/    /'
    VALIDATE_FAIL=1
  fi
  # 6e) size cap (never upload a giant archive)
  if [ "$SIZE" -gt 1900000000 ]; then
    log "ERROR: archive too large (${SIZEH})"; VALIDATE_FAIL=1
  fi
fi
if [ $VALIDATE_FAIL -ne 0 ]; then
  log "Archive validation FAILED — upload skipped; previous healthy state is untouched."
  sudo rm -f /tmp/state.tar.gz
  exit 1
fi
phase "validation PASS (members=${ACTUAL} expected=${EXPECTED} size=${SIZEH})"

# ----------------------------------------------------------- 7) upload
if upload_state /tmp/state.tar.gz; then
  STATUS=0
else
  STATUS=1
  log "ERROR: state upload failed (previous healthy state untouched)"
fi
sudo rm -rf "$META" "$SNAP_DIR"
sudo rm -f /tmp/state.tar.gz
phase "snapshot attempt finished (exit=$STATUS)"
exit $STATUS
