#!/usr/bin/env python3
# emg4: تست قطعی polling ربات hermes + ری‌استارت gateway در صورت لزوم
import subprocess,os,re,json,urllib.request,urllib.error,time,glob
def sh(c,t=70):
    try:
        p=subprocess.run(c,shell=True,capture_output=True,text=True,timeout=t); return (p.stdout+p.stderr).strip()
    except Exception as e: return "(err:%s)"%e
def sect(t): print("\n== "+t+"\n"+"-"*58)
def api(tok,method,timeout=12):
    try:
        with urllib.request.urlopen("https://api.telegram.org/bot%s/%s"%(tok,method),timeout=timeout) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        try: return json.loads(e.read().decode("utf-8","replace"))
        except Exception: return {"ok":False,"error":"httperr"}
    except Exception as e: return {"ok":False,"error":str(e)[:60]}

sect("۱) پیدا کردن توکن ربات hermes")
cands=set()
for f in ("/root/.local/share/tirith/last_trigger.json","/root/.hermes/.env"):
    try:
        t=open(f,encoding="utf-8",errors="replace").read()
        cands.update(re.findall(r"\d{8,12}:[A-Za-z0-9_\-]{30,}",t))
    except Exception: pass
print("candidates:",len(cands))
hermes=None
for t in cands:
    j=api(t,"getMe")
    u=(j.get("result") or {}).get("username")
    if j.get("ok"): print("  ok: user=%s"%u)
    if u=="hermesultimatehamidbot": hermes=t; break
print("token hermes:", "پیدا شد" if hermes else "پیدا نشد")
sect("۲) تست قطعی: کسی poll می‌کند؟")
if hermes:
    j=api(hermes,"getUpdates?offset=-1&timeout=0")
    print("getUpdates ok=%s desc=%s n=%s"%(j.get("ok"),(j.get("description") or "-")[:90],len(j.get("result") or [])))
    conflict = "Conflict" in str(j.get("description") or "")
    w=(api(hermes,"getWebhookInfo").get("result") or {})
    pend=w.get("pending_update_count",0); print("pending=%s url=%s"%(pend,w.get("url") or "(none)"))
    sect("۳) اقدام")
    if conflict:
        print("یک poller فعال است (Conflict) → ربات زنده است؛ pending=%s"%pend)
    elif pend>0:
        print("کسی poll نمی‌کند → ری‌استارت gateway")
        print(sh("ps -ef | grep -E 'gateway run|hermes' | grep -v grep | head -6"))
        ppid=sh("ps -o ppid= -p 9869 2>/dev/null").strip()
        if ppid: print("والد 9869:", sh("ps -o pid,ppid,cmd -p "+ppid+" 2>/dev/null"))
        print("kill:", sh("pkill -f 'hermes_cli.main gateway run'; sleep 2; pgrep -af 'gateway run' | head -3; echo done"))
        print("restart:", sh("cd /root && HOME=/root PATH=/usr/local/lib/hermes-agent/venv/bin:$PATH nohup python -m hermes_cli.main gateway run >/root/.hermes/logs/gateway-restart.log 2>&1 & sleep 10; pgrep -af 'gateway run' | head -3"))
        time.sleep(15)
        w2=(api(hermes,"getWebhookInfo").get("result") or {})
        print("pending بعد از ری‌استارت: %s"%w2.get("pending_update_count"))
        if w2.get("pending_update_count",0)>0:
            time.sleep(15)
            w3=(api(hermes,"getWebhookInfo").get("result") or {})
            print("pending نهایی: %s"%w3.get("pending_update_count"))
        print("لاگ restart:", sh("tail -15 /root/.hermes/logs/gateway-restart.log 2>/dev/null | sed 's/[0-9]\\{8,12\\}:[A-Za-z0-9_-]\\{30,\\}/<TOKEN>/g' | head -18"))
    else:
        print("pending=0 → کسی لازم نیست؛ ربات اوکی است")
sect("۴) سرویس‌های کلیدی + دسترسی داشبورد")
print(sh("systemctl is-active hermes-dashboard hermes-tunnel nginx 2>/dev/null | tr '\\n' ' '; echo; curl -s -o /dev/null -w 'dashboard=%{http_code}\\n' -m 6 http://127.0.0.1:9120/"))
sect("۵) لاگ‌های gateway (تازه)")
print(sh("ls -t /root/.hermes/logs/*.log 2>/dev/null | head -5"))
print(sh("tail -12 /root/.hermes/logs/gateway_faulthandler.log 2>/dev/null | head -14"))
print(sh("tail -6 /root/.hermes/gateway-starts.log 2>/dev/null"))
print("== EMG4 DONE ==")
