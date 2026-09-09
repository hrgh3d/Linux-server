#!/bin/bash
# ============================================================================
# save.sh (v5) — اسنپ‌شات «داده/تنظیمات کاربر» + کاتالوگ پکیج‌ها
#
#   payload  = فقط Configuration/Data در ریشه‌های persist.list (payload.py)
#              فایل‌های نصب پکیج‌ها (node_modules/venv/binary/…) شامل نیستند.
#   catalog  = installed.json شامل پکیج‌های apt/npm/pip کاربر برای بازنصب.
#   آرشیو    = _meta/… + درخت payload؛ آپلود rolling تک‌نسخه‌ای (skip بی‌تغییر).
# ============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/common.sh"

LOCK=/tmp/persist-save.lock
exec 9>"$LOCK"
if ! flock -n 9; then
  log "Another save is already running — skipping this invocation."
  exit 0
fi

META=/tmp/persist-meta
LIST=/tmp/payload.list
STATS=/tmp/payload.stats.json
sudo rm -rf "$META"; mkdir -p "$META/_meta"; rm -f "$LIST" "$STATS"

T0=$(date +%s)
phase() { echo "[persist $(date -u '+%T') +$(( $(date +%s) - T0 ))s] $*"; }
log "Starting v5 payload snapshot..."

# ----------------------------------------------------------- 1) package data
if command -v dpkg >/dev/null 2>&1; then
  timeout 90 dpkg --get-selections > "$META/_meta/packages.list" 2>/dev/null || true
fi
if command -v apt-mark >/dev/null 2>&1; then
  timeout 60 apt-mark showmanual > "$META/_meta/manual_packages.list" 2>/dev/null || true
fi
# پکیج‌های apt کاربر = manual فعلی منهای پایه‌ی image
if [ -f /tmp/base_manual_packages.list ]; then
  comm -23 <(sort "$META/_meta/manual_packages.list" 2>/dev/null) \
            <(sort /tmp/base_manual_packages.list 2>/dev/null) \
    | grep -vxE 'tailscale|tailscale-archive-keyring' \
    > "$META/_meta/user_packages.list" 2>/dev/null || true
fi

# کاتالوگ پکیج‌ها (apt/npm/pip) به‌صورت JSON
APT_LIST="$META/_meta/user_packages.list"
NPM_CUR="$META/_meta/npm.cur.txt"; PIP_CUR="$META/_meta/pip.cur.txt"
: > "$NPM_CUR"; : > "$PIP_CUR"
if command -v npm >/dev/null 2>&1; then
  timeout 60 npm ls -g --depth=0 --json 2>/dev/null \
    | jq -r '.dependencies | keys[]' 2>/dev/null | sort > "$NPM_CUR" || true
fi
if command -v pip3 >/dev/null 2>&1; then
  timeout 60 pip3 list --format=freeze 2>/dev/null | cut -d= -f1 | sort > "$PIP_CUR" || true
fi
# diff با پایه‌ی image ثبت‌شده در ابتدای Boot
comm -13 <(sort /tmp/base_npm.list 2>/dev/null) <(sort "$NPM_CUR") > "$META/_meta/user_npm.list" 2>/dev/null || true
comm -13 <(sort /tmp/base_pip.list 2>/dev/null) <(sort "$PIP_CUR") > "$META/_meta/user_pip.list" 2>/dev/null || true

python3 - "$META/_meta" <<'PY'
import datetime, json, os, sys
meta = sys.argv[1]
def read(name):
    p = os.path.join(meta, name)
    return [l.strip() for l in open(p) if l.strip()] if os.path.exists(p) else []
catalog = {
    "schema": "v5",
    "apt":   read("user_packages.list"),
    "npm":   read("user_npm.list"),
    "pip":   read("user_pip.list"),
}
catalog["meta"] = {
    "run_id": os.environ.get("GITHUB_RUN_ID", "local"),
    "boot_ts": os.environ.get("BOOT_TS", ""),
    "saved_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
open(os.path.join(meta, "installed.json"), "w").write(json.dumps(catalog, indent=2))
print("[persist] catalog: apt=%d npm=%d pip=%d" % (len(catalog["apt"]), len(catalog["npm"]), len(catalog["pip"])))
PY

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
  --out "$LIST" --base /tmp --stats "$STATS"
RC=$?
if [ $RC -ne 0 ] || [ ! -s "$LIST" ]; then
  log "ERROR: payload scan failed"
  exit 1
fi
cat "$STATS" 2>/dev/null | jq -c '{dirs,files,links,mb,top:.["top"],top2:.["top2"],big:.["big"],skipped_big:.["skipped_big"]}' | sed 's/^/[persist] stats /' || true

# ----------------------------------------------------------- 4) tar
phase "creating archive..."
sudo rm -f /tmp/state.tar.gz
set +e
# -v goes to tar.log so on failure we can see the last file tar was working
# on; inner timeout 300 prevents a stuck read from burning the whole step.
timeout 300 sudo tar -v --use-compress-program='gzip -1' -cf /tmp/state.tar.gz \
  -C / -T "$LIST" --no-recursion \
  -C "$META" _meta \
  >/tmp/tar.log 2>&1
RC=$?
set -e
if [ $RC -ne 0 ]; then
  log "ERROR: tar failed/timed out (rc=$RC). Last files processed:"
  tail -15 /tmp/tar.log 2>/dev/null | sed 's/^/    /'
  sudo rm -f /tmp/state.tar.gz
  exit 1
fi
sudo chown "$(id -u):$(id -g)" /tmp/state.tar.gz 2>/dev/null || true
SIZE=$(stat -c%s /tmp/state.tar.gz 2>/dev/null || echo 0)
SIZEH=$(du -h /tmp/state.tar.gz | cut -f1)
DIGEST=$(sha256sum /tmp/state.tar.gz | cut -d' ' -f1)
phase "archive created: ${SIZEH} (${SIZE} bytes) sha256=${DIGEST:0:16}"

if [ "$SIZE" -gt 1900000000 ]; then
  log "ERROR: archive too large (${SIZEH}) — aborting upload."
  sudo rm -f /tmp/state.tar.gz
  exit 1
fi

# ----------------------------------------------------------- 5) upload
if upload_state /tmp/state.tar.gz; then
  STATUS=0
else
  STATUS=$?
  log "ERROR: state upload failed"
fi
sudo rm -rf "$META" /tmp/state.tar.gz
phase "snapshot attempt finished (exit=$STATUS)"
exit $STATUS
