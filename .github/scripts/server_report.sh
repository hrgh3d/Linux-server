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
sudo ssh-keygen -lf /etc/ssh/ssh_host_*_key 2>/dev/null | sed 's/^/    /' || echo "    (none)"
FIXED_SHA=$(sha256sum .github/ssh/id_ed25519.pub 2>/dev/null | cut -d' ' -f1)
H_SHA=$(sudo sha256sum /home/Hamid/.ssh/authorized_keys 2>/dev/null | cut -d' ' -f1)
R_SHA=$(sudo sha256sum /root/.ssh/authorized_keys 2>/dev/null | cut -d' ' -f1)
echo "fixed key present Hamid: $(sudo grep -cF "$(tr -d '\r\n' < .github/ssh/id_ed25519.pub)" /home/Hamid/.ssh/authorized_keys 2>/dev/null || true)"
echo "fixed key present root : $(sudo grep -cF "$(tr -d '\r\n' < .github/ssh/id_ed25519.pub)" /root/.ssh/authorized_keys 2>/dev/null || true)"

echo ""
echo "---- 4) Tailscale ----"
echo "ip4=${TS_IP:-pending}"
sudo tailscale status 2>/dev/null | head -5 || echo "(tailscale not running)"

echo ""
echo "---- 5) Persistence probe (path/name-agnostic) ----"
for f in /root/persistence-probe/root.txt /var/lib/persistence-probe-z9x/state.data /etc/persistence-probe.conf /home/Hamid/persistence-probe.txt /opt/persistence-probe/app.cfg; do
  if sudo test -f "$f"; then echo "found: $f -> $(sudo cat "$f" 2>/dev/null | head -1)"; else echo "missing: $f"; fi
done
if command -v htop >/dev/null 2>&1; then echo "htop installed : yes"; else echo "htop installed : no"; fi
if command -v cowsay >/dev/null 2>&1; then echo "cowsay installed : yes"; else echo "cowsay installed : no"; fi
echo "9router  bin : $([ -x /usr/local/bin/9router ] && echo present || echo missing)"
echo "hermes   bin : $([ -x /usr/local/bin/hermes ] && echo present || echo missing)"
echo "hermes   data: $(sudo test -d /root/.hermes && echo present || echo missing)"
echo "3x-ui    bin : $([ -x /usr/local/x-ui/x-ui ] && echo present || echo missing)"
echo "3x-ui    etc : $([ -d /etc/x-ui ] && echo present || echo missing)"

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
    sudo ssh-keygen -lf /etc/ssh/ssh_host_*_key 2>/dev/null
    echo '```'
    echo "</details>"
  } >> "$GITHUB_STEP_SUMMARY"
fi
