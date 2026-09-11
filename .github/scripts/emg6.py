#!/usr/bin/env python3
# emg6: پاک‌سازی همه نمونه‌ها → فقط یونیت systemd → تأیید polling و drain شدن pending
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
ENV="XDG_RUNTIME_DIR=/run/user/0 "
sect("۱) علت کرش یونیت (لاگ)")
print(sh(ENV+"journalctl --user -u hermes-gateway -n 30 --no-pager 2>&1 | tail -22 | sed 's/[0-9]\\{8,12\\}:[A-Za-z0-9_-]\\{30,\\}/<TOKEN>/g'"))
sect("۲) پاک‌سازی کامل و استارت تمیز واحد")
print(" stop:", sh(ENV+"systemctl --user stop hermes-gateway 2>&1; echo rc=$?"))
print(" kill همه نمونه‌ها:", sh("pkill -f 'hermes_cli.main gateway run'; sleep 3; pgrep -af 'gateway run' | head -5; echo done"))
print(" start:", sh(ENV+"systemctl --user start hermes-gateway 2>&1; sleep 14; "+ENV+"systemctl --user is-active hermes-gateway"))
print(" پروسه‌ها:", sh("ps -eo pid,ppid,etime,cmd | grep 'gateway run' | grep -v grep | head -5"))
sect("۳) تأیید polling")
print(sh("tail -14 /root/.hermes/logs/gateway.log 2>/dev/null | sed 's/[0-9]\\{8,12\\}:[A-Za-z0-9_-]\\{30,\\}/<TOKEN>/g' | grep -iE 'telegram|gateway.run' | tail -8"))
sect("۴) pending و poller")
cands=[]
for f in ("/root/.local/share/tirith/last_trigger.json","/root/.hermes/.env"):
    try:
        t=open(f,encoding="utf-8",errors="replace").read(); cands+=re.findall(r"\d{8,12}:[A-Za-z0-9_\-]{30,}",t)
    except Exception: pass
tok=None
for t in set(cands):
    if (api(t,"getMe").get("result") or {}).get("username")=="hermesultimatehamidbot": tok=t; break
if tok:
    for i in range(6):
        w=(api(tok,"getWebhookInfo").get("result") or {})
        p=w.get("pending_update_count")
        print("  نمونه %d: pending=%s"%(i,p))
        if p==0 and i>0: break
        time.sleep(8)
    j=api(tok,"getUpdates?offset=-1&timeout=0")
    print("  poller:", "Conflict ✅ (یک poller فعال)" if "Conflict" in str(j.get("description") or "") else str(j.get("description") or j)[:90])
sect("۵) وضعیت پایدار")
print(sh("ps -eo pid,ppid,etime,cmd | grep 'gateway run' | grep -v grep | head -4"))
print(sh(ENV+"systemctl --user status hermes-gateway --no-pager 2>&1 | head -12 | sed 's/[0-9]\\{8,12\\}:[A-Za-z0-9_-]\\{30,\\}/<TOKEN>/g'"))
print("== EMG6 DONE ==")
