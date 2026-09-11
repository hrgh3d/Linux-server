#!/usr/bin/env python3
# emg7: تأیید نهایی polling ربات hermes (نمونهٔ تازهٔ gateway + drain شدن pending)
import subprocess,os,re,json,time,urllib.request,urllib.error
def sh(c,t=70):
    try:
        p=subprocess.run(c,shell=True,capture_output=True,text=True,timeout=t); return (p.stdout+p.stderr).strip()
    except Exception as e: return "(err:%s)"%e
def sect(t): print("\n== "+t+"\n"+"-"*58)
def api(tok,method,timeout=25):
    try:
        with urllib.request.urlopen("https://api.telegram.org/bot%s/%s"%(tok,method),timeout=timeout) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        try: return json.loads(e.read().decode("utf-8","replace"))
        except Exception: return {"ok":False}
    except Exception: return {"ok":False}
ENV="XDG_RUNTIME_DIR=/run/user/0 "
sect("۱) سرویس و پروسه")
print(sh(ENV+"systemctl --user is-active hermes-gateway; ps -eo pid,etime,cmd | grep 'gateway run' | grep -v grep | head -3"))
sect("۲) اتصال تلگرام (لاگ)")
print(sh("grep -a 'Connected to Telegram\\|Telegram menu\\|adapter' /root/.hermes/logs/gateway.log 2>/dev/null | tail -6 | sed 's/[0-9]\\{8,12\\}:[A-Za-z0-9_-]\\{30,\\}/<TOKEN>/g'"))
print(sh("journalctl --user -u hermes-gateway -n 40 --no-pager 2>/dev/null | grep -a -iE 'telegram|connected|error' | tail -8 | sed 's/[0-9]\\{8,12\\}:[A-Za-z0-9_-]\\{30,\\}/<TOKEN>/g'"))
sect("۳) pending (نمونه‌گیری ۶۰ ثانیه)")
cands=[]
for f in ("/root/.local/share/tirith/last_trigger.json","/root/.hermes/.env"):
    try:
        t=open(f,encoding="utf-8",errors="replace").read(); cands+=re.findall(r"\d{8,12}:[A-Za-z0-9_\-]{30,}",t)
    except Exception: pass
tok=None
for t in set(cands):
    if (api(t,"getMe").get("result") or {}).get("username")=="hermesultimatehamidbot": tok=t; break
last=None
if tok:
    for i in range(8):
        w=(api(tok,"getWebhookInfo").get("result") or {})
        last=w.get("pending_update_count")
        print("  t+%02ds pending=%s"%(i*8,last))
        if last==0: break
        time.sleep(8)
    j=api(tok,"getUpdates?offset=-1&timeout=0",timeout=15)
    desc=str(j.get("description") or "")
    print("  getUpdates:", "Conflict ✅ (poller فعال)" if "Conflict" in desc else ("آزاد — poller غیرفعال" if j.get("ok") else desc[:80]))
sect("۴) اگر آزاد بود: تلاش نهایی ری‌استارت با انتظار بیشتر")
if tok and last and last>0:
    print(" ری‌استارت:", sh(ENV+"systemctl --user restart hermes-gateway 2>&1; sleep 25; "+ENV+"systemctl --user is-active hermes-gateway"))
    for i in range(5):
        w=(api(tok,"getWebhookInfo").get("result") or {}); print("  بعد از ری‌استارت t+%02ds pending=%s"%(i*8,w.get("pending_update_count")))
        if w.get("pending_update_count")==0: break
        time.sleep(8)
    print(sh("tail -6 /root/.hermes/logs/gateway.log | sed 's/[0-9]\\{8,12\\}:[A-Za-z0-9_-]\\{30,\\}/<TOKEN>/g'"))
sect("۵) وضعیت نهایی")
print(sh(ENV+"systemctl --user status hermes-gateway --no-pager 2>&1 | head -8"))
print("== EMG7 DONE ==")
