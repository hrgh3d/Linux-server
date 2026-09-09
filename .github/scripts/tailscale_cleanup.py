#!/usr/bin/env python3
"""
tailscale_cleanup.py (v4) — Tailnet hygiene helper.

* Determines the CURRENT node from local `tailscale status --json`.
* Deletes ONLY devices that:
    - belong to this server's hostname family (e.g. linux-server-vps,
      linux-server-vps-1, linux-server-vps-2, ...), AND
    - are OFFLINE, AND
    - are NOT the current node.
  Online devices and unrelated devices are NEVER touched.
* Optionally renames the current node to the exact hostname when it has a
  numeric suffix (so the name never drifts to linux-server-vps-1).

Usage: tailscale_cleanup.py   (env: TAILSCALE_API_TOKEN, TS_HOSTNAME)
"""
import sys
import os
import json
import time
import subprocess
import urllib.request
import urllib.error

API = "https://api.tailscale.com/api/v2"


def local_self():
    try:
        out = subprocess.check_output(
            ["sudo", "tailscale", "status", "--json"], stderr=subprocess.DEVNULL)
        body = json.loads(out.decode())
        # وقتی tailscaled متوقف/بدون-state است، Self یا TailscaleIPs ممکن است
        # null باشند (باگ v5.1: 'NoneType' object is not iterable) — همه None-safe.
        s = body.get("Self") or {}
        nodekey = s.get("PublicKey") or s.get("NodeKey") or ""
        return {
            "id": s.get("ID", ""),
            "nodekey": nodekey,
            "ips": set(s.get("TailscaleIPs") or []),
            "hostname": s.get("HostName", ""),
            "online": bool(s.get("Online")),
        }
    except Exception as e:
        print(f"[ts-clean] warn: cannot read local tailscale status: {e}", file=sys.stderr)
        return {"id": "", "nodekey": "", "ips": set(), "hostname": "", "online": False}


def api_get(devices_url, token):
    req = urllib.request.Request(devices_url, headers={
        "Authorization": f"Bearer {token}", "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())


def api_delete(device_id, token):
    req = urllib.request.Request(f"{API}/device/{device_id}",
                                 headers={"Authorization": f"Bearer {token}"},
                                 method="DELETE")
    with urllib.request.urlopen(req, timeout=30):
        return True


def api_rename(device_id, name, token):
    body = json.dumps({"name": name}).encode()
    req = urllib.request.Request(f"{API}/device/{device_id}/name", data=body,
                                 headers={"Authorization": f"Bearer {token}",
                                          "Content-Type": "application/json"},
                                 method="POST")
    with urllib.request.urlopen(req, timeout=30):
        return True


def main():
    token = os.environ.get("TAILSCALE_API_TOKEN")
    target = os.environ.get("TS_HOSTNAME") or "linux-server-vps"
    if not token or token == "NOT_SET":
        print("[ts-clean] TAILSCALE_API_TOKEN not set; skipping cleanup.")
        return

    self_ = local_self()
    print(f"[ts-clean] local node: hostname={self_['hostname']} online={self_['online']} "
          f"ips={sorted(self_['ips'])}")
    try:
        data = api_get(f"{API}/tailnet/-/devices?fields=all", token)
    except Exception as e:
        print(f"[ts-clean] warn: cannot list devices: {e}", file=sys.stderr)
        return

    devices = data.get("devices") or []
    deleted, renamed = 0, 0
    online_target = None
    my_device = None

    for d in devices:
        host = (d.get("hostname") or "").lower()
        name = (d.get("name") or "").lower()
        is_family = host == target.lower() or \
            host.startswith(target.lower() + "-") or \
            host.startswith(target.lower() + ".") or \
            name.startswith(target.lower() + ".")

        d_addrs = set(d.get("addresses", []))
        d_key = d.get("nodeKey", "")
        is_self = bool(self_["nodekey"] and d_key == self_["nodekey"]) or \
                  bool(self_["ips"] and (self_["ips"] & d_addrs))

        if is_self:
            my_device = d
            continue
        if not is_family:
            continue

        if d.get("online"):
            # یک node هم‌نام آنلاین دیگر — حذف نمی‌کنیم ولی ثبت می‌کنیم
            online_target = d
            continue

        # آفلاین، هم‌خانواده، و متعلق به ما نیست → پاکسازی امن
        print(f"[ts-clean] deleting stale offline node {d.get('name')} "
              f"(id={d.get('id')}, addrs={list(d_addrs)})")
        try:
            api_delete(d["id"], token)
            deleted += 1
            time.sleep(0.3)
        except Exception as e:
            print(f"[ts-clean] warn: delete failed for {d.get('id')}: {e}", file=sys.stderr)

    # اصلاح نام node فعلی اگر پسوند عددی گرفته باشد
    if my_device:
        cur_host = (my_device.get("hostname") or "").lower()
        if cur_host != target.lower():
            if online_target is None:
                print(f"[ts-clean] renaming current node to exact hostname '{target}'")
                try:
                    api_rename(my_device["id"], target, token)
                    renamed = 1
                except Exception as e:
                    print(f"[ts-clean] warn: rename failed: {e}", file=sys.stderr)
            else:
                print(f"[ts-clean] not renaming (another online node keeps the name).")
    print(f"[ts-clean] done: deleted={deleted} renamed={renamed}")


if __name__ == "__main__":
    main()
