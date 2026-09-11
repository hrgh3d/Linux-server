#!/usr/bin/env python3
# emg3: یافتن و بالا آوردن poller ربات hermes روی hrgh3d
import subprocess,os,re,json,urllib.request,glob
def sh(c,t=70):
    try:
        p=subprocess.run(c,shell=True,capture_output=True,text=True,timeout=t); return (p.stdout+p.stderr).strip()
    except Exception as e: return "(err:%s)"%e
def sect(t): print("\n== "+t+"\n"+"-"*58)
sect("۱) سرویس‌های hermes/tirith/gateway")
print(sh("systemctl list-unit-files 2>/dev/null | grep -iE 'hermes|tirith|gateway|bot' | head -15"))
print("units:", sh("systemctl list-units --all 2>/dev/null | grep -iE 'hermes|tirith|gateway' | head -12"))
sect("۲) تعریف سرویس‌ها")
print(sh("systemctl cat hermes-dashboard.service 2>/dev/null | head -24"))
print("---tunnel---"); print(sh("systemctl cat hermes-tunnel.service 2>/dev/null | head -16"))
sect("۳) ساختار hermes-agent")
print(sh("ls /usr/local/lib/hermes-agent/ 2>/dev/null | head -20"))
print("bins:", sh("ls /usr/local/bin/ 2>/dev/null | grep -iE 'hermes|tirith' ; ls /usr/local/lib/hermes-agent/venv/bin/ 2>/dev/null | grep -iE 'hermes|tirith' | head"))
sect("۴) پیکربندی ربات‌ها")
print(" .hermes:", sh("ls -la /root/.hermes/ 2>/dev/null | head -15"))
print(" tirith:", sh("ls -la /root/.local/share/tirith/ 2>/dev/null | head -12"))
print(" فایل‌های مرتبط:", sh("grep -rl 'hermesultimatehamidbot' /root /etc /opt /usr/local/lib/hermes-agent /srv 2>/dev/null | grep -v venv | head -10"))
print(" last_trigger:", sh("cat /root/.local/share/tirith/last_trigger.json 2>/dev/null | head -c 300 | sed 's/[0-9]\\{8,12\\}:[A-Za-z0-9_-]\\{30,\\}/<TOKEN>/g'"))
sect("۵) لاگ‌های hermes")
print(" journal dashboard:", sh("journalctl -u hermes-dashboard -n 25 --no-pager 2>/dev/null | tail -18"))
for f in glob.glob("/root/.hermes/*.log")+glob.glob("/root/.hermes/logs/*.log")+glob.glob("/root/*.log")+glob.glob("/var/log/hermes*.log"):
    print(" --- "+f)
    print(sh("tail -12 "+f+" 2>/dev/null | sed 's/[0-9]\\{8,12\\}:[A-Za-z0-9_-]\\{30,\\}/<TOKEN>/g' | head -14"))
sect("۶) تست زندهٔ getUpdates (بدون مصرف کردن)")
env=sh("cat /root/.hermes/.env 2>/dev/null | sed 's/[0-9]\\{8,12\\}:[A-Za-z0-9_-]\\{30,\\}/TOKEN/g'")
print(" .env (ماسک‌شده):", env[:600])
tok=None
m=re.search(r"\d{8,12}:[A-Za-z0-9_\-]{30,}", open("/root/.local/share/tirith/last_trigger.json",encoding="utf-8",errors="replace").read() if os.path.exists("/root/.local/share/tirith/last_trigger.json") else "")
if m: tok=m.group(0)
if tok:
    try:
        j=json.load(urllib.request.urlopen("https://api.telegram.org/bot%s/getUpdates?offset=-1&timeout=0"%(tok),timeout=10))
        res=j.get("result") or []
        if res:
            u=res[-1]; msg=u.get("message") or {}
            print(" آخرین آپدیت: update_id=%s از %s — تاریخ %s"%(u.get("update_id"),(msg.get("from") or {}).get("username") or (msg.get("from") or {}).get("id"), msg.get("date")))
        else: print(" هیچ آپدیتی نیست")
        w=json.load(urllib.request.urlopen("https://api.telegram.org/bot%s/getWebhookInfo"%tok,timeout=10)).get("result") or {}
        print(" pending=%s"%(w.get("pending_update_count"),))
    except Exception as e: print(" err:",str(e)[:80])
sect("۷) پروسه‌ها و پورت‌ها")
print(sh("ps -ef | grep -iE 'hermes|tirith' | grep -v grep | head -12"))
print(sh("ss -ltnp 2>/dev/null | grep -E '9119|9120|20128|20241|20242' | head -10"))
sect("۸) تلاش بازیابی: سرویس‌های نامزد")
for u in ("hermes-gateway","hermes-bot","hermes","tirith","tirith-bot","hermes-agent"):
    st=sh("systemctl is-active "+u+" 2>/dev/null"); en=sh("systemctl is-enabled "+u+" 2>/dev/null")
    if en!="not-found":
        print(" %s active=%s enabled=%s"%(u,st,en))
        if st!="active":
            print("   استارت:", sh("systemctl start "+u+" 2>&1; sleep 2; systemctl is-active "+u)[:150])
print("== EMG3 DONE ==")
