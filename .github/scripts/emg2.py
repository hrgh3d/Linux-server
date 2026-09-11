#!/usr/bin/env python3
# emg2: تشخیص فوری ربات‌ها + hermes (hrgh3d)
import subprocess,os
def sh(c,t=70):
    try:
        p=subprocess.run(c,shell=True,capture_output=True,text=True,timeout=t); return (p.stdout+p.stderr).strip()
    except Exception as e: return "(err:%s)"%e
def sect(t): print("\n== "+t+"\n"+"-"*58)
sect("زمان/آپ‌تایم"); print(sh("date -u; uptime"))
sect("هرمس (hermes)"); print(sh("systemctl list-units --all 2>/dev/null | grep -i hermes | head -10"))
print("unit:", sh("ls /etc/systemd/system/ 2>/dev/null | grep -iE 'hermes|bot' | head -10"))
print("status:", sh("systemctl status hermes --no-pager 2>&1 | head -14"))
print("docker:", sh("docker ps -a 2>/dev/null | head -10"))
print("ps:", sh("ps aux | grep -iE 'hermes' | grep -v grep | head -8"))
sect("journal هرمس"); print(sh("journalctl -u hermes -n 40 --no-pager 2>&1 | tail -30"))
sect("ربات‌ها/سرویس‌های دیگر"); print(sh("systemctl list-units --type=service --all 2>/dev/null | grep -iE 'bot|vpn|mirza|xray|3x' | head -20"))
print("ps:", sh("ps aux | grep -iE 'bot|telegram|php|node|python' | grep -v grep | head -20"))
sect("کرون‌ها"); print(sh("cat /etc/cron.d/* 2>/dev/null | grep -vE '^#|^SHELL|^PATH' | head -20; crontab -l 2>/dev/null | head -10"))
sect("تلگرام از سرور"); print(sh("curl -sS -m 10 -o /dev/null -w 'api.telegram.org=%{http_code}\\n' https://api.telegram.org/ 2>&1"))
sect("توکن‌ها (جست‌وجوی امن، ماسک‌شده)")
find=sh("ls -d /root/*mirza* /root/*bot* /opt/* /var/www/* 2>/dev/null | head -20"); print("مسیرها:",find)
open("/root/_emg_scan.php","w").write('<?php
$dirs=array("/root","/opt","/var/www","/usr/local");
$toks=array();
foreach($dirs as $d){
  $it=new RecursiveIteratorIterator(new RecursiveDirectoryIterator($d,FilesystemIterator::SKIP_DOTS),RecursiveIteratorIterator::SELF_FIRST);
  $n=0;
  foreach($it as $f){ if($n++>400) break;
    if(!$f->isFile()) continue;
    $p=$f->getPathname();
    if(!preg_match("/\\.(php|env|json|py|js|txt|ini|conf)$/",$p)) continue;
    if($f->getSize()>400000) continue;
    $t=@file_get_contents($p); if($t===false) continue;
    if(preg_match_all("/[0-9]{8,12}:[A-Za-z0-9_\\-]{30,}/",$t,$m)){ foreach($m[0] as $x) $toks[$x]=$p; }
  }
}
echo "found=".count($toks)."\\n";
$seen=array();
foreach($toks as $t=>$p){
  $j=json_decode(@file_get_contents("https://api.telegram.org/bot".$t."/getMe"),true);
  $key=substr($t,0,10);
  if(isset($seen[$key])) continue; $seen[$key]=1;
  echo "…".substr($t,-6)." ok=".(($j["ok"]??false)?"true":"false")." user=".($j["result"]["username"]??"-")." file=".$p."\\n";
  $wj=json_decode(@file_get_contents("https://api.telegram.org/bot".$t."/getWebhookInfo"),true); $w=$wj["result"]??array();
  echo "   webhook=".($w["url"]?preg_replace("/[0-9]{8,12}:[A-Za-z0-9_\\-]{30,}/","<TOKEN>",$w["url"]):"(none)")." pending=".($w["pending_update_count"]??0)." err=".substr((string)($w["last_error_message"]??"-"),0,60)."\\n";
}
')
print(sh("php /root/_emg_scan.php 2>&1 | head -25"))
sh("rm -f /root/_emg_scan.php")
sect("تیل‌اسکیل/فانل"); print(sh("tailscale status 2>&1 | head -8; echo ---; tailscale funnel status 2>&1 | head -14"))
sect("لاگ‌های اخیر"); print(sh("journalctl -n 25 --no-pager 2>&1 | tail -20"))
sect("سرویس‌های keepalive/main"); print(sh("systemctl status keepalive --no-pager 2>&1 | head -8; ls /opt 2>/dev/null | head"))
print("=== EMG2 DONE ===")
