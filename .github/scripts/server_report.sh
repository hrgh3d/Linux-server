#!/bin/bash
# ============================================================================
# server_report.sh — بررسی و گزارش وضعیت سرور پس از Boot (v4)
#  خروجی: گزارش متنی + مقادیر برای GITHUB_STEP_SUMMARY
# ============================================================================
set -uo pipefail

echo "==================== LINUX-SERVER BOOT REPORT ===================="
echo "boot_ts=${BOOT_TS:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')} run_id=${GITHUB_RUN_ID:-?} attempt=${GITHUB_RUN_ATTEMPT:-1}"

echo ""
echo "---- 1) Persistence markers ----"
echo "Hamid marker : $(sudo cat /home/Hamid/persist-marker.txt 2>/dev/null || echo '(absent — fresh boot)')"
echo "root  marker : $(sudo cat /root/persist-marker.txt 2>/dev/null || echo '(absent — fresh boot)')"
echo "server-state : $(sudo cat /root/.server-state.json 2>/dev/null | head -c 600 || echo '(absent)')"
echo "root files   : $(sudo find /root -maxdepth 1 -type f 2>/dev/null | wc -l)"
echo "Hamid files  : $(sudo find /home/Hamid -maxdepth 1 -type f 2>/dev/null | wc -l)"

echo ""
echo "---- 2) sudo / root ----"
echo "Hamid exists         : $(id Hamid >/dev/null 2>&1 && echo yes || echo NO)"
echo "Hamid passwordless   : $(sudo -u Hamid sudo -n true 2>/dev/null && echo OK || echo FAIL)"
echo "Hamid 'sudo su'      : $(sudo -u Hamid sudo -n su -c 'echo root-ok' 2>/dev/null || echo FAIL)"
echo "root password state  : $(sudo passwd -S root 2>/dev/null || echo unknown)"

echo ""
echo "---- 3) SSH ----"
echo "sshd running         : $(pgrep -x sshd >/dev/null && echo yes || echo NO)"
echo "port 22              : $(sudo ss -tlnp 2>/dev/null | grep -c ':22 ')"
echo "host key fingerprints:"
# ssh-keygen -l فقط یک فایل می‌پذیرد (چند فایل = «Too many arguments») — تک‌تک.
_FOUND_FP=0
for _k in /etc/ssh/ssh_host_*_key; do
  [ -f "$_k" ] || continue
  _fp=$(sudo ssh-keygen -lf "$_k" 2>/dev/null) || continue
  echo "    ${_fp}"
  _FOUND_FP=1
done
[ "$_FOUND_FP" = 1 ] || echo "    (none)"
FIXED_SHA=$(sha256sum .github/ssh/id_ed25519.pub 2>/dev/null | cut -d' ' -f1)
H_SHA=$(sudo sha256sum /home/Hamid/.ssh/authorized_keys 2>/dev/null | cut -d' ' -f1)
R_SHA=$(sudo sha256sum /root/.ssh/authorized_keys 2>/dev/null | cut -d' ' -f1)
echo "fixed key present Hamid: $(sudo grep -cF "$(tr -d '\r\n' < .github/ssh/id_ed25519.pub)" /home/Hamid/.ssh/authorized_keys 2>/dev/null || true)"
echo "fixed key present root : $(sudo grep -cF "$(tr -d '\r\n' < .github/ssh/id_ed25519.pub)" /root/.ssh/authorized_keys 2>/dev/null || true)"

echo ""
echo "---- 4) Tailscale ----"
echo "ip4=${TS_IP:-pending}"
_TS_SELF_JSON=$(sudo tailscale status --json 2>/dev/null || true)
if [ -n "$_TS_SELF_JSON" ]; then
  echo "self: $(echo "$_TS_SELF_JSON" | jq -r '"\(.Self.HostName // "?") \((.Self.TailscaleIPs // []) | join(",")) online=\(.Self.Online // false)"' 2>/dev/null || echo '(parse error)')"
else
  echo "(tailscale not running)"
fi

echo ""
echo "---- 5) Persistence probe (path/name-agnostic) ----"
for f in /root/persistence-probe/root.txt /var/lib/persistence-probe-z9x/state.data /etc/persistence-probe.conf /home/Hamid/persistence-probe.txt /opt/persistence-probe/app.cfg; do
  if sudo test -f "$f"; then echo "found: $f -> $(sudo cat "$f" 2>/dev/null | head -1)"; else echo "missing: $f"; fi
done
if command -v htop >/dev/null 2>&1; then echo "htop installed : yes"; else echo "htop installed : no"; fi
if dpkg -s cowsay >/dev/null 2>&1; then echo "cowsay installed : yes ($(dpkg-query -W -f='${Version}' cowsay 2>/dev/null))"; else echo "cowsay installed : no"; fi
echo "9router  bin : $([ -x /usr/local/bin/9router ] && echo present || echo missing)"
echo "hermes   bin : $([ -x /usr/local/bin/hermes ] && echo present || echo missing)"
echo "hermes   data: $(sudo test -d /root/.hermes && echo present || echo missing)"
echo "3x-ui    bin : $([ -x /usr/local/x-ui/x-ui ] && echo present || echo missing)"
echo "3x-ui    etc : $([ -d /etc/x-ui ] && echo present || echo missing)"

echo ""
echo "---- 6) Payload root sizes (diagnostic) ----"
echo "var/lib largest:"
sudo du -sh /var/lib/* 2>/dev/null | sort -rh | head -6 | sed 's/^/    /'
echo "root top:"
sudo du -sh /root/.[!.]* /root/* 2>/dev/null | sort -rh | head -6 | sed 's/^/    /'

echo ""
echo "==================== END BOOT REPORT ===================="

# ---- Step Summary (GITHUB_STEP_SUMMARY)
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## 🟢 Linux-server is ready"
    echo ""
    echo "| Item | Value |"
    echo "|---|---|"
    echo "| Run | \`${GITHUB_RUN_ID:-?}\` (attempt ${GITHUB_RUN_ATTEMPT:-1}) |"
    echo "| Boot TS | \`${BOOT_TS:-?}\` |"
    echo "| User | \`root\` (primary) / \`Hamid\` |"
    echo "| Tailscale IPv4 | \`${TS_IP:-pending}\` |"
    echo "| MagicDNS | \`${TS_HOSTNAME:-linux-server-vps}\` |"
    echo "| SSH | \`ssh -i <private-key> root@${TS_IP:-<ip>}\` |"
    echo "| Root access | direct root login (passwordless) |"
    echo "| Hamid marker | \`$(sudo head -1 /home/Hamid/persist-marker.txt 2>/dev/null || echo fresh)\` |"
    echo "| Root marker | \`$(sudo head -1 /root/persist-marker.txt 2>/dev/null || echo fresh)\` |"
    echo ""
    echo "<details><summary>Host SSH key fingerprints</summary>"
    echo ""
    echo '```'
    _FOUND_FP=0
    for _k in /etc/ssh/ssh_host_*_key; do
      [ -f "$_k" ] || continue
      _fp=$(sudo ssh-keygen -lf "$_k" 2>/dev/null) || continue
      echo "    ${_fp}"
      _FOUND_FP=1
    done
    [ "$_FOUND_FP" = 1 ] || echo "    (none)"
    echo '```'
    echo "</details>"
  } >> "$GITHUB_STEP_SUMMARY"
fi
