#!/usr/bin/env python3
"""
tailscale_cleanup.py — Safely removes offline, stale duplicate nodes from the Tailnet
while NEVER touching the active online node.
"""
import sys
import os
import urllib.request
import urllib.error
import json
import subprocess

def get_current_tailscale_info():
    try:
        out = subprocess.check_output(["sudo", "tailscale", "status", "--json"], stderr=subprocess.DEVNULL)
        data = json.loads(out.decode())
        self_data = data.get("Self", {})
        ips = self_data.get("TailscaleIPs", [])
        public_key = self_data.get("PublicKey") or self_data.get("NodeKey") or ""
        hostname = self_data.get("HostName", "")
        return {
            "ips": set(ips),
            "key": public_key,
            "hostname": hostname,
            "online": self_data.get("Online", False)
        }
    except Exception as e:
        print(f"[tailscale-clean] warn: could not query local tailscale status: {e}", file=sys.stderr)
        return {"ips": set(), "key": "", "hostname": "", "online": False}

def cleanup_stale_nodes(api_token, target_hostname):
    current = get_current_tailscale_info()
    print(f"[tailscale-clean] Current node IPs: {list(current['ips'])}, online: {current['online']}")
    
    headers = {
        "Authorization": f"Bearer {api_token}",
        "Accept": "application/json",
        "User-Agent": "Linux-server-tailscale-cleaner"
    }
    url = "https://api.tailscale.com/api/v2/tailnet/-/devices"
    req = urllib.request.Request(url, headers=headers)
    
    try:
        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read().decode())
    except Exception as e:
        print(f"[tailscale-clean] warn: could not list tailnet devices: {e}", file=sys.stderr)
        return

    devices = data.get("devices", [])
    for d in devices:
        d_id = d.get("id")
        d_hostname = d.get("hostname", "")
        d_name = d.get("name", "")
        d_online = d.get("connectedToControl", False)
        d_addrs = set(d.get("addresses", []))
        d_key = d.get("nodeKey", "")
        
        # Check if this device matches target hostname
        matches_name = (d_hostname.lower() == target_hostname.lower() or 
                        d_name.lower().startswith(f"{target_hostname.lower()}."))
        
        if not matches_name:
            continue
            
        # Is this the currently active node?
        is_current = False
        if current["ips"] and (current["ips"] & d_addrs):
            is_current = True
        if current["key"] and d_key == current["key"]:
            is_current = True
            
        if is_current or d_online:
            print(f"[tailscale-clean] Keeping active node: {d_name} ({d_id}, IP: {list(d_addrs)})")
            continue
            
        # If it matches name but is offline and not the current node, delete it
        print(f"[tailscale-clean] Deleting stale offline node: {d_name} (ID: {d_id}, IP: {list(d_addrs)})")
        del_url = f"https://api.tailscale.com/api/v2/device/{d_id}"
        del_req = urllib.request.Request(del_url, headers=headers, method="DELETE")
        try:
            with urllib.request.urlopen(del_req) as del_resp:
                print(f"[tailscale-clean] Successfully deleted stale node {d_id}")
        except Exception as err:
            print(f"[tailscale-clean] warn: failed to delete node {d_id}: {err}", file=sys.stderr)

def main():
    api_token = os.environ.get("TAILSCALE_API_TOKEN")
    target_hostname = os.environ.get("TS_HOSTNAME") or "linux-server-vps"
    
    if not api_token or api_token == "NOT_SET":
        print("[tailscale-clean] TAILSCALE_API_TOKEN not provided, skipping stale cleanup.")
        return
        
    cleanup_stale_nodes(api_token, target_hostname)

if __name__ == "__main__":
    main()
