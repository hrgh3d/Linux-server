#!/bin/bash
# ============================================================================
# router_password_guard.sh (v6.20)
#
# مسئله‌ای که حل می‌کند
# ---------------------
# رمز ورود پنل 9router در جدول settings (ستون data، کلید JSON به نام
# "password") داخل دیتابیس /root/.9router/db/data.sqlite و به شکل bcrypt
# ذخیره می‌شود. این رمز «بین رانرها» گم می‌شد، چون:
#
#   1) اگر دیتابیس در state موجود نباشد یا اپ آن را تازه بسازد، 9router یک
#      نصب تازه می‌سازد و رمز به پیش‌فرض 123456 برمی‌گردد.
#   2) SQLite در حالت WAL کار می‌کند. payload.py فایل‌های -wal/-shm را از
#      آرشیو حذف می‌کند، پس اگر تغییرِ رمز فقط در WAL مانده باشد و
#      checkpoint نشده باشد، آن تغییر وارد بکاپ نمی‌شود و بعد از بازیابی،
#      رمزِ قدیمی/پیش‌فرض برمی‌گردد.
#
# این اسکریپت در هر بوت (بعد از start-services) اجرا می‌شود و تضمین می‌کند
# رمز پنل همیشه برابر با ROUTER_PASSWORD (از GitHub Secret) باشد.
# Idempotent است: اگر رمز از قبل درست باشد، هیچ نوشتنی انجام نمی‌دهد.
#
# امنیت: مقدار رمز هرگز چاپ نمی‌شود؛ فقط وضعیت (already-correct / updated).
# ============================================================================
set -uo pipefail

DB=/root/.9router/db/data.sqlite
PW="${ROUTER_PASSWORD:-}"

log() { echo "[rpw $(date -u '+%T')] $*"; }

if [ -z "$PW" ]; then
  log "WARN: ROUTER_PASSWORD not set — skipping (panel keeps whatever it has)"
  exit 0
fi

# ۱) صبر کوتاه تا اپ دیتابیس را بسازد (نصب تازه)
for i in $(seq 1 20); do
  [ -f "$DB" ] && break
  sleep 1
done
if [ ! -f "$DB" ]; then
  log "WARN: $DB not present after wait — 9router may not be installed; skipping"
  exit 0
fi

# ۲) اطمینان از وجود ماژول bcrypt برای پایتون
if ! python3 -c "import bcrypt" >/dev/null 2>&1; then
  log "installing python3 bcrypt..."
  pip3 install --break-system-packages -q bcrypt >/dev/null 2>&1 \
    || sudo apt-get install -y -o DPkg::Lock::Timeout=120 python3-bcrypt >/dev/null 2>&1
fi
if ! python3 -c "import bcrypt" >/dev/null 2>&1; then
  log "ERROR: bcrypt unavailable — cannot enforce panel password"
  exit 0
fi

# ۳) بررسی/تنظیم رمز. اگر نیاز به تغییر بود سرویس را متوقف می‌کنیم تا
#    نوشتن امن باشد و اپ مقدار قدیمی را دوباره روی آن ننویسد.
NEED=$(ROUTER_PASSWORD="$PW" python3 - "$DB" <<'PY'
import sqlite3, json, os, sys
db = sys.argv[1]
pw = os.environ["ROUTER_PASSWORD"].encode()
try:
    import bcrypt
    c = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=15)
    row = c.execute("select data from settings where id=1").fetchone()
    c.close()
    if not row:
        print("yes"); sys.exit(0)
    d = json.loads(row[0])
    cur = (d.get("password") or "").encode()
    if cur and bcrypt.checkpw(pw, cur):
        print("no")
    else:
        print("yes")
except Exception:
    print("yes")
PY
)

if [ "$NEED" = "no" ]; then
  log "panel password already correct — no change"
  # حتی وقتی تغییری لازم نیست، WAL را checkpoint می‌کنیم تا رمزِ درست
  # حتماً داخل فایل اصلی دیتابیس باشد و در بکاپ بعدی ثبت شود.
  python3 - "$DB" <<'PY' 2>/dev/null || true
import sqlite3, sys
c = sqlite3.connect(sys.argv[1], timeout=15)
c.execute("PRAGMA wal_checkpoint(TRUNCATE)")
c.commit(); c.close()
PY
  exit 0
fi

log "panel password differs from secret — enforcing..."
WAS_ACTIVE=$(systemctl is-active 9router 2>/dev/null || echo unknown)
sudo systemctl stop 9router >/dev/null 2>&1 || true
sleep 1

ROUTER_PASSWORD="$PW" python3 - "$DB" <<'PY'
import sqlite3, json, os, sys
import bcrypt
db = sys.argv[1]
pw = os.environ["ROUTER_PASSWORD"].encode()
c = sqlite3.connect(db, timeout=20)
row = c.execute("select data from settings where id=1").fetchone()
d = json.loads(row[0]) if row else {}
d["password"] = bcrypt.hashpw(pw, bcrypt.gensalt(10)).decode()
if row:
    c.execute("update settings set data=? where id=1", (json.dumps(d),))
else:
    c.execute("insert into settings (id, data) values (1, ?)", (json.dumps(d),))
c.commit()
# مهم: WAL را داخل فایل اصلی بنویس تا بکاپِ فایل‌محور (که -wal را حذف
# می‌کند) رمز جدید را از دست ندهد.
try:
    c.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    c.commit()
except Exception as e:
    print("[rpw] checkpoint warn:", e)
chk = json.loads(c.execute("select data from settings where id=1").fetchone()[0])
c.close()
print("[rpw] verify:", "MATCH_OK" if bcrypt.checkpw(pw, chk["password"].encode()) else "MISMATCH")
PY

if [ "$WAS_ACTIVE" = "active" ] || [ "$WAS_ACTIVE" = "unknown" ]; then
  sudo systemctl start 9router >/dev/null 2>&1 || true
fi
sleep 3
log "panel password enforced (service: $(systemctl is-active 9router 2>/dev/null))"
exit 0
