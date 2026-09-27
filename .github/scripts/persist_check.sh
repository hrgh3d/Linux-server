#!/bin/bash
# ============================================================================
# persist_check.sh — آیا محیط Hermes/OmniRoute از تعویض رانر جان سالم برد؟
#
# چرا لازم است: سه بار پشت سر هم «حدس زدم» چیزی از بین رفته و دو بارش
# اشتباه بود (نوسان اعداد از نشست‌های تست خودم بود). حدس جای اندازه‌گیری
# را نمی‌گیرد. این اسکریپت وضعیت فعلی را با مانیفستِ ثبت‌شده مقایسه
# می‌کند و صریح می‌گوید چه چیزی کم شده.
#
#   persist_check.sh            → مقایسه با مانیفست
#   persist_check.sh --record   → ثبت وضعیت فعلی به‌عنوان مبنای تازه
# ============================================================================
set -uo pipefail
M=/root/.hermes/PERSIST_MANIFEST.json
export HERMES_HOME=/root/.hermes

python3 - "${1:-}" "$M" <<'PY'
import json, os, sqlite3, subprocess, sys, datetime

mode, MAN = sys.argv[1], sys.argv[2]

def q(db, sql):
    try:
        c = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=5)
        v = c.execute(sql).fetchone()[0]; c.close(); return v
    except Exception:
        return None

def count_dir(p):
    return len(os.listdir(p)) if os.path.isdir(p) else 0

def env_keys(p):
    try:
        return sum(1 for l in open(p, errors="replace")
                   if "=" in l and not l.startswith("#")
                   and len(l.split("=", 1)[1].strip()) >= 4)
    except OSError:
        return 0

def canary():
    try:
        t = open("/root/.hermes/CANARY.md").read()
        return t.split("—")[-1].strip().splitlines()[0]
    except Exception:
        return None

def svc(n, user=False):
    cmd = ["systemctl"] + (["--user"] if user else []) + ["is-active", n]
    e = {**os.environ, "XDG_RUNTIME_DIR": "/run/user/0"}
    return subprocess.run(cmd, capture_output=True, text=True, env=e).stdout.strip()

def http(u):
    r = subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                        "-m", "12", u], capture_output=True, text=True)
    return r.stdout.strip()

ts_ip = subprocess.run(["tailscale", "ip", "-4"], capture_output=True,
                       text=True).stdout.split("\n")[0].strip()

now = {
 "stamp": canary(),
 "hermes": {
   "sessions":  q("/root/.hermes/state.db", "select count(*) from sessions"),
   "messages":  q("/root/.hermes/state.db", "select count(*) from messages"),
   "skills":    count_dir("/root/.hermes/skills"),
   "profiles":  count_dir("/root/.hermes/profiles"),
   "kanban_tables": q("/root/.hermes/kanban.db",
                      "select count(*) from sqlite_master where type='table'"),
   "env_keys":  env_keys("/root/.hermes/.env"),
 },
 "omniroute": {
   "providers": q("/root/.omniroute/storage.sqlite",
                  "select count(*) from provider_connections"),
   "api_keys":  q("/root/.omniroute/storage.sqlite", "select count(*) from api_keys"),
   "jobs":      q("/root/.omniroute/storage.sqlite", "select count(*) from jobs"),
   "call_logs": q("/root/.omniroute/storage.sqlite", "select count(*) from call_logs"),
 },
}

if mode == "--record":
    now["recorded_at"] = datetime.datetime.utcnow().isoformat(timespec="seconds")
    with open(MAN, "w") as f:
        json.dump(now, f, indent=1, ensure_ascii=False)
    print(json.dumps(now, indent=1, ensure_ascii=False))
    print("\n✓ مبنای تازه ثبت شد")
    raise SystemExit(0)

try:
    old = json.load(open(MAN))
except Exception:
    print("مانیفستی نیست — اول با --record ثبتش کن"); raise SystemExit(2)

print(f"مبنا: {old.get('recorded_at', old.get('stamp'))}   قناری: {now['stamp']}")
print(f"{'':2}{'مورد':<28}{'مبنا':>8}{'اکنون':>9}   وضعیت")
bad = 0
# شمارنده‌های لاگ‌مانند طبیعتاً رشد می‌کنند؛ فقط کاهش مهم است
for grp in ("hermes", "omniroute"):
    for k, o in (old.get(grp) or {}).items():
        n = (now.get(grp) or {}).get(k)
        if o is None or n is None:
            state = "؟ خوانده نشد"
        elif n >= o:
            state = "✅" + ("" if n == o else f" (+{n-o})")
        else:
            state = f"❌ کم شد ({o-n})"; bad += 1
        print(f"  {grp+'.'+k:<28}{str(o):>8}{str(n):>9}   {state}")

print("\n  سرویس‌ها و دسترسی‌ها")
checks = [
  ("hermes-serve",        svc("hermes-serve"), "active"),
  ("hermes-gateway(user)", svc("hermes-gateway.service", user=True), "active"),
  ("omniroute",           svc("omniroute"), "active"),
  ("env-vault.timer",     svc("env-vault.timer"), "active"),
  ("hermes-serve-guard",  svc("hermes-serve-guard.timer"), "active"),
  ("omniroute-guard",     svc("omniroute-guard.timer"), "active"),
]
for name, got, want in checks:
    ok = got == want
    bad += 0 if ok else 1
    print(f"  {name:<30}{got:>10}   {'✅' if ok else '❌'}")

for name, url, want in [
  ("serve (محلی)",  f"http://{ts_ip}:9122/api/status", "200"),
  ("funnel (اینترنت)", "https://linux-server-vps.tail3641f4.ts.net:10000/api/status", "200"),
  ("omniroute panel", "https://linux-server-vps.tail3641f4.ts.net:9447/", "307"),
]:
    got = http(url); ok = got == want
    bad += 0 if ok else 1
    print(f"  {name:<30}{got:>10}   {'✅' if ok else '❌ انتظار '+want}")

print("\n" + ("✅ همه‌چیز سالم است" if bad == 0 else f"❌ {bad} ایراد — بالا را ببین"))
raise SystemExit(1 if bad else 0)
PY
