#!/usr/bin/env python3
# emg2b: بررسی و بازیابی ربات‌ها + hermes روی hrgh3d (بدون php — فقط python)
import subprocess,os,re,json,urllib.request
def sh(c,t=70):
    try:
        p=subprocess.run(c,shell=True,capture_output=True,text=True,timeout=t); return (p.stdout+p.stderr).strip()
    except Exception as e: return "(err:%s)"%e
def sect(t): print("\n== "+t+"\n"+"-"*58)
sect("زمان/آپ‌تایم/ری‌استارت‌ها"); print(sh("date -u; uptime -p; uptime -s; echo ---; last -x 2>/dev/null | head -8; echo ---; journalctl --list-boots 2>/dev/null | tail -4"))
sect("سرویس‌های ربات/Heremes")
print(sh("systemctl list-units --type=service --all 2>/dev/null | grep -iE 'bot|hermes|vpn|xray|3x|node|panel|dash' | head -25"))
print("unit-files:", sh("systemctl list-unit-files 2>/dev/null | grep -iE 'bot|hermes|vpn|xray|3x|panel|dash' | head -20"))
sect("وضعیت تفصیلی هر سرویس نامزد")
for u in ("hermes","hermes-agent","9router","dashboard","x-ui","3x-ui","nginx","mirza-bot","vpnbot","telegram-bot"):
    st=sh("systemctl is-active "+u+" 2>/dev/null"); en=sh("systemctl is-enabled "+u+" 2>/dev/null")
    if st not in ("inactive","") or en not in ("not-found",""):
        d=sh("systemctl show -p Description --value "+u+" 2>/dev/null")
        print(" %-14s active=%-10s enabled=%-12s %s"%(u,st,en,d[:40]))
        if st=="inactive" and en in ("enabled","enabled-runtime"):
            print("   → استارت:", sh("systemctl start "+u+" 2>&1; sleep 2; systemctl is-active "+u)[:120])
sect("داکر"); print(sh("docker ps -a 2>/dev/null | head -12 || echo no-docker"))
sect("پروسه‌ها"); print(sh("ps aux | grep -iE 'hermes|bot|node|python|9router|dash' | grep -v grep | head -22"))
sect("pm2",); print(sh("pm2 list 2>/dev/null | head -12 || echo no-pm2"))
sect("پوشه‌های کاندید"); print(sh("ls /opt 2>/dev/null; echo ---; ls /root 2>/dev/null | head -20; echo ---; ls /srv /var/www 2>/dev/null | head -12"))
sect("کرون‌ها"); print(sh("cat /etc/cron.d/* 2>/dev/null | grep -vE '^#|^SHELL|^PATH' | head -20; crontab -l 2>/dev/null | head -10"))
sect("تلگرام/شبکه"); print(sh("curl -sS -m 10 -o /dev/null -w 'api.telegram.org=%{http_code}\\n' https://api.telegram.org/ 2>&1; ss -ltn 2>/dev/null | awk 'NR>1{print $4}' | sort -u | head -14"))
sect("توکن‌ها (اسکن پایتونی، ماسک‌شده)")
pat=re.compile(r"\d{8,12}:[A-Za-z0-9_\-]{30,}")
found={}
for root in ("/root","/opt","/var/www","/usr/local","/srv","/etc"):
    if not os.path.isdir(root): continue
    for dp,dn,fn in os.walk(root):
        if any(x in dp for x in ("/node_modules","/.git","/proc","/sys","/snap","/cache","/dist","/build")): dn[:]=[]; continue
        if dp.count("/")>5: dn[:]=[]; continue
        for f in fn:
            if not f.endswith((".php",".env",".json",".py",".js",".txt",".ini",".conf",".yaml",".yml",".sh")): continue
            p=os.path.join(dp,f)
            try:
                if os.path.getsize(p)>400000: continue
                t=open(p,encoding="utf-8",errors="replace").read()
            except Exception: continue
            for m in pat.findall(t): found.setdefault(m,p)
print("tokens found:",len(found))
for t,p in list(found.items())[:8]:
    try:
        j=json.load(urllib.request.urlopen("https://api.telegram.org/bot%s/getMe"%t,timeout=10))
        print("  …%s ok=%s user=%s file=%s"%(t[-6:],j.get("ok"),(j.get("result") or {}).get("username"),p))
        w=json.load(urllib.request.urlopen("https://api.telegram.org/bot%s/getWebhookInfo"%t,timeout=10)).get("result") or {}
        print("     webhook=%s pending=%s err=%s"%(pat.sub("<TOKEN>",w.get("url") or "(none)"),w.get("pending_update_count"),(w.get("last_error_message") or "-")[:60]))
    except Exception as e: print("  …%s err=%s"%(t[-6:],str(e)[:60]))
sect("لاگ‌های تازه سیستم"); print(sh("journalctl -n 30 --no-pager 2>&1 | tail -24"))
print("== EMG2B DONE ==")
