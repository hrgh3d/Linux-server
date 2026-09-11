#!/usr/bin/env python3
# emg5: تثبیت یک نمونه gateway + تأیید polling + بررسی یونیت systemd و ری‌استارت‌لوپ
import subprocess,os,re,json,time,urllib.request,urllib.error
def sh(c,t=70):
    try:
        p=subprocess.run(c,shell=True,capture_output=True,text=True,timeout=t); return (p.stdout+p.stderr).strip()
    except Exception as e: return "(err:%s)"%e
def sect(t): print("\n== "+t+"\n"+"-"*58)
def api(tok,method,timeout=10):
    try:
        with urllib.request.urlopen("https://api.telegram.org/bot%s/%s"%(tok,method),timeout=timeout) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        try: return json.loads(e.read().decode("utf-8","replace"))
        except Exception: return {"ok":False}
    except Exception: return {"ok":False}
sect("۱) نمونه‌های gateway")
print(sh("ps -eo pid,ppid,lstart,cmd | grep -E 'gateway run' | grep -v grep | head -8"))
sect("۲) یونیت‌های سطح کاربر (systemd --user)")
print(sh("XDG_RUNTIME_DIR=/run/user/0 systemctl --user list-units --all 2>&1 | grep -iE 'hermes|gateway|tirith' | head -10"))
print(sh("ls -la /root/.config/systemd/user/ 2>/dev/null | head -12"))
print(sh("systemctl --user is-active hermes-gateway 2>&1 | head -2"))
print("linger:", sh("loginctl show-user root 2>/dev/null | grep -i linger"))
sect("۳) ری‌استارت‌لوپ؟ (شمارش استارت‌ها در ۲ دقیقه)")
print(" starts tail:", sh("tail -8 /root/.hermes/gateway-starts.log"))
print(" exit-diag tail:", sh("tail -12 /root/.hermes/logs/gateway-exit-diag.log 2>/dev/null | sed 's/[0-9]\\{8,12\\}:[A-Za-z0-9_-]\\{30,\\}/<TOKEN>/g' | head -14"))
print(" gateway.log tail:", sh("tail -10 /root/.hermes/logs/gateway.log 2>/dev/null | sed 's/[0-9]\\{8,12\\}:[A-Za-z0-9_-]\\{30,\\}/<TOKEN>/g' | head -12"))
sect("۴) تثبیت: فقط یک نمونه، ترجیحاً یونیت systemd")
uni=sh("XDG_RUNTIME_DIR=/run/user/0 systemctl --user list-unit-files 2>/dev/null | grep -iE 'hermes|gateway' | head -4")
print("unit-files:", uni)
m=re.search(r'^(\S+\.service)\s', uni or "")
row=sh("ps -eo pid,ppid,cmd | grep 'gateway run' | grep -v grep | head -6")
rows=[l.split(None,2) for l in row.splitlines() if l.strip()]
info=[]
for r in rows:
    pid=int(r[0]); ppid=int(r[1])
    pcmd=sh("ps -o comm= -p %d 2>/dev/null"%ppid)
    info.append((pid,ppid,pcmd))
print(" samples:", info)
if m:
    unit=m.group(1)
    # نمونه‌های nohup (والد sh/nohup/bash) را بکش، یونیت را ری‌استارت کن
    for pid,ppid,pcmd in info:
        if "systemd" not in pcmd:
            print(" kill nohup", pid, "→", sh("kill %d 2>/dev/null; echo ok"%pid))
    print(" restart unit:", sh("XDG_RUNTIME_DIR=/run/user/0 systemctl --user restart "+unit+" 2>&1; sleep 8; XDG_RUNTIME_DIR=/run/user/0 systemctl --user is-active "+unit))
else:
    pids=[i[0] for i in info]
    if len(pids)>1:
        keep=pids[-1]
        for pid in pids[:-1]:
            if pid!=keep: print(" kill extra", pid, sh("kill %d 2>/dev/null; echo ok"%pid))
print(" بعد از تثبیت:", sh("ps -eo pid,ppid,cmd | grep 'gateway run' | grep -v grep | head -6"))
sect("۵) نمونه‌گیری pending (تا ۴۰ ثانیه)")
cands=[]
for f in ("/root/.local/share/tirith/last_trigger.json","/root/.hermes/.env"):
    try:
        t=open(f,encoding="utf-8",errors="replace").read(); cands+=re.findall(r"\d{8,12}:[A-Za-z0-9_\-]{30,}",t)
    except Exception: pass
tok=None
for t in set(cands):
    j=api(t,"getMe")
    if (j.get("result") or {}).get("username")=="hermesultimatehamidbot": tok=t; break
print("token:", "ok" if tok else "not found")
if tok:
    for i in range(5):
        w=(api(tok,"getWebhookInfo").get("result") or {})
        print("  نمونه %d: pending=%s"%(i,w.get("pending_update_count")))
        if w.get("pending_update_count")==0 and i>0: break
        time.sleep(9)
    j=api(tok,"getUpdates?offset=-1&timeout=0")
    print("  وضعیت poller:", "Conflict (زنده و فعال)" if "Conflict" in str(j.get("description") or "") else ("آزاد — کسی poll نمی‌کند!" if j.get("ok") else str(j)[:80]))
sect("۶) وضعیت سرویس‌ها")
print(sh("systemctl is-active hermes-dashboard hermes-tunnel nginx 2>/dev/null | tr '\\n' ' '"))
print("== EMG5 DONE ==")
