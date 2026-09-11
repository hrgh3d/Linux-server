#!/bin/bash
# check_notify.sh — روی سرور: وضعیت فایل env و توکن ربات را گزارش می‌کند (مقادیر ماسک).
set -u
echo "--- files ---"
ls -la /root/.hermes/ 2>/dev/null | head -12 || echo "(no /root/.hermes)"
for f in /root/.hermes/.env /root/hermes/.env /opt/hermes/.env /root/9router/.env; do
  [ -f "$f" ] && { echo "$f: $(stat -c '%s bytes %U:%G %A' "$f")"; grep -c . "$f" | sed 's/^/  lines=/'; }
done
echo "--- keys in /root/.hermes/.env (values masked) ---"
if [ -f /root/.hermes/.env ]; then
  while IFS= read -r line; do
    k="${line%%=*}"; v="${line#*=}"
    printf '  %s = <len %s>\n' "$k" "${#v}"
  done < /root/.hermes/.env
else
  echo "  (file missing)"
fi
echo "--- any TELEGRAM_BOT_TOKEN elsewhere? ---"
for d in /root /etc /opt /srv /var/www; do
  grep -rl '^TELEGRAM_BOT_TOKEN=' "$d" 2>/dev/null | head -4
done
echo "--- hermes-related services/units ---"
systemctl list-units --all --no-legend 2>/dev/null | grep -iE 'hermes|9router|agent' | head -6 || echo "(none)"
echo "--- is anything polling the bot? (processes) ---"
ps -eo pid,etime,cmd 2>/dev/null | grep -iE 'hermes|telegram|9router' | grep -v grep | head -6 || echo "(none)"
echo "DONE"
