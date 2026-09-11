#!/usr/bin/env python3
# inv_hrg: لیست دقیق ربات‌ها روی hrgh3d + وضعیت هر کدام
import subprocess,os,re,json,time,urllib.request,urllib.error
def sh(c,t=80):
    try:
        p=subprocess.run(c,shell=True,capture_output=True,text=True,timeout=t); return (p.stdout+p.stderr).strip()
    except Exception as e: return "(err:%s)"%e
def sect(t): print("\n== "+t+"\n"+"-"*58)
def api(tok,method,timeout=10):
    try:
        with urllib.request.urlopen("https://api.telegram.org/bot%s/%s"%(tok,method),timeout=timeout) as r: return json.load(r)
    except urllib.error.HTTPError as e:
        try: return json.loads(e.read().decode("utf-8","replace"))
        except Exception: return {"ok":False}
    except Exception: return {"ok":False}
def mask(s): return re.sub(r"\d{8,12}:[A-Za-z0-9_\-]{30,}","<TOKEN>",s or "")
PAT=re.compile(r"\d{8,12}:[A-Za-z0-9_\-]{30,}")
sect("۱) توکن‌های ربات روی سرور")
found={}
for root in ("/root","/etc","/opt","/usr/local/bin","/srv"):
    if not os.path.isdir(root): continue
    for dp,dn,fn in os.walk(root):
        if any(x in dp for x in ("/venv","/node_modules","/tests","/__pycache__","/.git","/snap")): dn[:]=[]; continue
        if dp.count("/")>5: dn[:]=[]; continue
        for f in fn:
            if not f.endswith((".env",".json",".yaml",".yml",".txt",".ini",".conf",".sh",".py")): continue
            p=os.path.join(dp,f)
            try:
                if os.path.getsize(p)>500000: continue
                t=open(p,encoding="utf-8",errors="replace").read()
            except Exception: continue
            for m in PAT.findall(t): found.setdefault(m,set()).add(p)
print(" tokens:",len(found))
sect("۲) وضعیت هر توکن")
for t,fs in sorted(found.items(), key=lambda x:-len(x[1])):
    j=api(t,"getMe"); r=j.get("result") or {}
    u=r.get("username") or "? (401?)"
    w=(api(t,"getWebhookInfo").get("result") or {})
    g=api(t,"getUpdates?offset=-1&timeout=0"); d=str(g.get("description") or "")
    state="Conflict → poller فعال ✅" if "Conflict" in d else ("آزاد — هیچ poller ❌" if g.get("ok") else d[:50])
    print("  @%s"%u)
    print("     pending=%-3s webhook=%-8s %s"%(w.get("pending_update_count"),("yes" if w.get("url") else "no"),state))
    print("     files: %s"%(", ".join(sorted(fs))[:150]))
sect("۳) gateway هرmes چه رباتی را poll می‌کند")
print(sh("grep -a 'Connected to Telegram\\|polling confirmed' /root/.hermes/logs/gateway.log 2>/dev/null | tail -3 | sed 's/[0-9]\\{8,12\\}:[A-Za-z0-9_-]\\{30,\\}/<TOKEN>/g'"))
print(" توکن فعال .env:", sh("grep -a '^TELEGRAM_BOT_TOKEN' /root/.hermes/.env 2>/dev/null | sed 's/[0-9]\\{8,12\\}:[A-Za-z0-9_-]\\{30,\\}/<TOKEN>/g'"))
print(" کاربران مجاز:", sh("grep -a 'TELEGRAM_ALLOWED_USERS' /root/.hermes/.env 2>/dev/null | head -2 | sed 's/=/ = /'"))
sect("۴) سرویس‌ها")
print(sh("XDG_RUNTIME_DIR=/run/user/0 systemctl --user is-active hermes-gateway 2>&1"))
print(sh("systemctl is-active hermes-dashboard hermes-tunnel nginx 2>&1 | tr '\\n' ' '"))
print(" dashboard:", sh("curl -s -o /dev/null -w '%{http_code}' -m 6 http://127.0.0.1:9120/"))
sect("۵) سایر برنامه‌های وب (20128?)")
print(sh("ss -ltnp 2>/dev/null | grep -E ':20128' | head -2"))
print(sh("ps -eo pid,cmd | grep -E 'next-server' | grep -v grep | head -2"))
print("== INV_HRG DONE ==")
