#!/usr/bin/env python3
# emg8: کدام ربات‌ها به gateway وصل‌اند؟ (hermesultimatehamidbot / tirith) + تصمیم
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
def mask(s): return re.sub(r"\d{8,12}:[A-Za-z0-9_\-]{30,}","<TOKEN>",s or "")
sect("۱) کانال‌های gateway: کدام ربات‌ها؟")
cfg=""
for f in ("/root/.hermes/config.yaml","/root/.hermes/config.yml","/root/.hermes/.env"):
    if os.path.exists(f):
        print(" --- "+f+" (خطوط مربوط به telegram/bot/username)")
        t=open(f,encoding="utf-8",errors="replace").read()
        for ln in t.splitlines():
            if re.search(r"(?i)telegram|bot_?token|username|channel|enabled", ln) and not ln.strip().startswith("#"):
                print("   "+mask(ln)[:120])
sect("۲) توکن‌ها و ربات‌هایشان + pending هرکدام")
cands={}
for root in ("/root","/opt","/usr/local/lib/hermes-agent","/srv"):
    if not os.path.isdir(root): continue
    for dp,dn,fn in os.walk(root):
        if any(x in dp for x in ("/node_modules","/.git","/proc","/venv/lib","/__pycache__")): dn[:]=[]; continue
        if dp.count("/")>6: dn[:]=[]; continue
        for f in fn:
            if not f.endswith((".env",".json",".yaml",".yml",".txt",".ini",".conf",".py")): continue
            p=os.path.join(dp,f)
            try:
                if os.path.getsize(p)>500000: continue
                t=open(p,encoding="utf-8",errors="replace").read()
            except Exception: continue
            for m in re.findall(r"\d{8,12}:[A-Za-z0-9_\-]{30,}",t): cands.setdefault(m,set()).add(p)
print(" distinct tokens:",len(cands))
for t,fs in cands.items():
    j=api(t,"getMe"); u=(j.get("result") or {}).get("username") or "?"
    w=(api(t,"getWebhookInfo").get("result") or {})
    print("  %-26s pending=%-3s webhook=%-8s files=%s"%(u,w.get("pending_update_count"),("yes" if w.get("url") else "no"),", ".join(sorted(fs))[:110]))
sect("۳) وضعیت tirith (اگر ربات مربوط به آن است)")
print(sh("systemctl list-units --all 2>/dev/null | grep -i tirith | head -5; ls /root/.config/systemd/user/ 2>/dev/null | head; ps -ef | grep -i tirith | grep -v grep | head -4"))
print("tirith dir:", sh("ls -la /root/.local/share/tirith/ 2>/dev/null | head -8"))
print("tirith log tail:", sh("tail -4 /root/.local/share/tirith/log.jsonl 2>/dev/null | cut -c1-220 | sed 's/[0-9]\\{8,12\\}:[A-Za-z0-9_-]\\{30,\\}/<TOKEN>/g'"))
sect("۴) gateway چه رباتی را poll می‌کند؟ (از لاگ اتصالش)")
print(sh("grep -a -iE 'telegram.*(connected|polling|bot|username)' /root/.hermes/logs/gateway.log 2>/dev/null | tail -8 | sed 's/[0-9]\\{8,12\\}:[A-Za-z0-9_-]\\{30,\\}/<TOKEN>/g'"))
sect("۵) وضعیت سرویس‌ها")
print(sh("XDG_RUNTIME_DIR=/run/user/0 systemctl --user is-active hermes-gateway hermes-dashboard 2>&1 | tr '\\n' ' '; systemctl is-active hermes-tunnel nginx | tr '\\n' ' '"))
print("== EMG8 DONE ==")
