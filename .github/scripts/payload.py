#!/usr/bin/env python3
"""
payload.py (v5) — walks the "data/config roots" listed in persist.list and
emits the exact member list for the state archive (a payload of user
Configuration + Data only). Install/cache/toolchain bulk is excluded here,
because packages are reinstalled from the package catalog instead of being
backed up.

Design goals
  * Path/name agnostic: any file a package creates inside a scanned root is
    captured automatically (no hardcoded per-package paths).
  * Minimal size: excludes caches, node_modules, language toolchains,
    runner-image bulk and known code-install trees.

Usage:
  payload.py list --roots persist.list --out /tmp/payload.list
                  [--base /tmp] [--stats /tmp/payload.stats.json]
  payload.py selftest
"""
import argparse
import json
import os
import stat
import sys

# Directory names skipped wherever they appear (any depth).
PRUNE_DIR_NAMES = {
    ".cache", "__pycache__", ".git", ".npm", ".nvm", ".bun", ".rustup",
    ".cargo", ".dotnet", ".pip", ".venv", "venv", "node_modules",
    "hostedtoolcache", "containerd", "target", ".pytest_cache",
    ".mypy_cache", ".tox", ".nox", ".gradle", ".nuget", ".conda",
    "audio_cache", "image_cache", "video_cache", "browser_cache",
    "logs", "tmp", "Trash",
}

# File names / suffixes skipped anywhere.
PRUNE_FILE_NAMES = {
    ".bash_history", ".zsh_history", ".wget-hsts", ".lesshst",
    "derpmap.cached.json",
}
PRUNE_FILE_SUFFIXES = (".sock", ".pid", ".lock", ".pyc", ".log", ".tmp")

# Absolute code/install trees -> reinstalled from catalog, not backed up.
PRUNE_ABS_DIRS = [
    "usr/local/lib/node_modules",
    "usr/local/lib/hermes-agent",
    "usr/local/share/uv",
    "usr/local/x-ui/bin",
]
PRUNE_ABS_FILES = [
    "usr/local/x-ui/x-ui",
    "usr/local/x-ui/mtg",
]

# /etc host/image transient entries never stored.
PRUNE_ETC = {
    "etc/resolv.conf", "etc/resolvconf", "etc/hostname", "etc/hosts",
    "etc/machine-id", "etc/mtab", "etc/fstab", "etc/network", "etc/netplan",
    "etc/cloud", "etc/apt", "etc/ssl", "etc/alternatives", "etc/ld.so.cache",
    "etc/sudoers", "etc/sudoers.d", "etc/shadow", "etc/shadow-",
    "etc/gshadow", "etc/gshadow-", "etc/passwd", "etc/passwd-",
    "etc/group", "etc/group-", "etc/subuid", "etc/subuid-",
    "etc/subgid", "etc/subgid-", "etc/skel", "etc/ssh/sshd_config.d",
}

# /var/lib runner-image subtrees (not user state).
PRUNE_VARLIB = {
    "var/lib/apt", "var/lib/dpkg", "var/lib/docker", "var/lib/containerd",
    "var/lib/snapd", "var/lib/systemd", "var/lib/private", "var/lib/misc",
    "var/lib/NetworkManager", "var/lib/plymouth", "var/lib/polkit-1",
    "var/lib/udisks2", "var/lib/accounts", "var/lib/colord",
    "var/lib/PackageKit", "var/lib/fwupd", "var/lib/gvfs",
    "var/lib/update-notifier", "var/lib/ubuntu-advantage",
    "var/lib/command-not-found", "var/lib/aptitude", "var/lib/sgml-base",
    "var/lib/xml-core", "var/lib/usb_modeswitch", "var/lib/open-iscsi",
    "var/lib/rpm", "var/lib/cni", "var/lib/kubelet", "var/lib/etcd",
    "var/lib/waagent", "var/lib/journal", "var/lib/bluetooth",
    "var/lib/selinux", "var/lib/php", "var/lib/postgresql",
    "var/lib/mysql", "var/lib/redis", "var/lib/nginx",
    "var/lib/postfix", "var/lib/amazon", "var/lib/google",
    "var/lib/gems", "var/lib/nodejs",
}

_BASE = {"usr/local/bin": set(), "usr/local/sbin": set(), "opt": set()}


def load_base(base_dir):
    mapping = {
        "usr/local/bin": os.path.join(base_dir, "base_usrlocalbin.list"),
        "usr/local/sbin": os.path.join(base_dir, "base_usrlocalsbin.list"),
        "opt": os.path.join(base_dir, "base_opt_entries.list"),
    }
    for relroot, path in mapping.items():
        names = set()
        if os.path.isfile(path):
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    n = line.strip()
                    if n:
                        names.add(n)
        _BASE[relroot] = names


def prune_dir(rel):
    name = rel.rstrip("/").rsplit("/", 1)[-1]
    if name in PRUNE_DIR_NAMES:
        return True
    if rel in PRUNE_ABS_DIRS or any(rel.startswith(d + "/") for d in PRUNE_ABS_DIRS):
        return True
    if rel.startswith("etc/") and rel in PRUNE_ETC:
        return True
    if rel.startswith("var/lib/"):
        if rel in PRUNE_VARLIB or any(rel.startswith(d + "/") for d in PRUNE_VARLIB):
            return True
    return False


def prune_file(rel):
    name = rel.rsplit("/", 1)[-1]
    if name in PRUNE_FILE_NAMES or name.endswith(PRUNE_FILE_SUFFIXES):
        return True
    if rel in PRUNE_ABS_FILES or any(rel.startswith(d + "/") for d in PRUNE_ABS_DIRS):
        return True
    if rel in PRUNE_ETC or rel in PRUNE_VARLIB or \
            any(rel.startswith(d + "/") for d in PRUNE_VARLIB):
        return True
    # skip image-baseline entries at the top level of bin/sbin/opt
    for base_root in ("usr/local/bin", "usr/local/sbin", "opt"):
        prefix = base_root + "/"
        if rel.startswith(prefix):
            rest = rel[len(prefix):]
            if "/" not in rest and rest in _BASE.get(base_root, ()):
                return True
    return False


def walk_abs(absdir, members):
    """Recursively walk absdir; add dirs/files/links to members (global rel)."""
    parent_rel = os.path.relpath(absdir, "/")
    base_root = parent_rel if parent_rel in _BASE else None
    try:
        entries = sorted(os.scandir(absdir), key=lambda e: e.name)
    except OSError:
        return
    for e in entries:
        full = os.path.join(absdir, e.name)
        rel = os.path.relpath(full, "/")
        # Image-baseline top-level entries (files OR dirs) of /opt and
        # /usr/local/bin|sbin are runner-image bulk -> never stored. User
        # additions get their own new names, which are not in the baseline.
        if base_root is not None and e.name in _BASE[base_root]:
            continue
        try:
            st = e.stat(follow_symlinks=False)
        except OSError:
            continue
        if stat.S_ISDIR(st.st_mode):
            if prune_dir(rel):
                continue
            members.add((rel, "d"))
            walk_abs(full, members)
        elif stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode):
            if prune_file(rel):
                continue
            members.add((rel, "l" if stat.S_ISLNK(st.st_mode) else "f"))


def collect(root_file, out_file, base_dir, stats_file=None):
    load_base(base_dir)
    roots = []
    with open(root_file, "r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if os.path.isdir(line):
                roots.append(line)
    members = set()  # (rel, kind)
    for root in roots:
        walk_abs(root, members)

    # ensure every ancestor dir is a member (directory modes are restored)
    for rel, kind in list(members):
        if kind == "f" or kind == "l":
            parts = rel.split("/")
            for i in range(1, len(parts)):
                d = "/".join(parts[:i])
                if os.path.isdir("/" + d):
                    members.add((d, "d"))

    counts = {"d": 0, "f": 0, "l": 0, "bytes": 0}
    top = {}
    top2 = {}
    for rel, kind in members:
        counts[kind] += 1
        if kind == "f":
            try:
                sz = os.path.getsize("/" + rel)
                counts["bytes"] += sz
                parts = rel.split("/")
                top[parts[0]] = top.get(parts[0], 0) + sz
                if len(parts) > 1:
                    key = parts[0] + "/" + parts[1]
                else:
                    key = parts[0]
                top2[key] = top2.get(key, 0) + sz
            except OSError:
                pass

    with open(out_file, "w", encoding="utf-8") as fh:
        for rel, _kind in sorted(members):
            fh.write(rel + "\n")
    if stats_file:
        with open(stats_file, "w", encoding="utf-8") as fh:
            json.dump({
                "roots": len(roots), "dirs": counts["d"], "files": counts["f"],
                "links": counts["l"], "bytes": counts["bytes"],
                "mb": round(counts["bytes"] / 1048576, 2),
                "top": sorted(top.items(), key=lambda x: -x[1])[:12],
                "top2": sorted(top2.items(), key=lambda x: -x[1])[:15],
            }, fh, indent=2)
    print(f"[payload] roots={len(roots)} members={len(members)} "
          f"dirs={counts['d']} files={counts['f']} links={counts['l']} "
          f"bytes={counts['bytes']} ({counts['bytes']/1048576:.1f} MB)")


def selftest():
    import tempfile
    root = tempfile.mkdtemp(prefix="pt")
    dirs = ["root/.config/app", "etc/app", "usr/local/bin",
            "root/node_modules/pkg", "var/lib/customx", "opt/userapp",
            "root/.hermes/logs"]
    for d in dirs:
        os.makedirs(root + "/" + d, exist_ok=True)
    open(root + "/root/.config/app/conf.json", "w").write("{}")
    open(root + "/etc/app/conf.ini", "w").write("x")
    open(root + "/usr/local/bin/mybin", "w").write("#!/bin/sh\n")
    open(root + "/root/node_modules/pkg/index.js", "w").write("big")
    open(root + "/var/lib/customx/data.db", "w").write("db")
    open(root + "/opt/userapp/main", "w").write("bin")
    open(root + "/root/.hermes/logs/a.log", "w").write("log")
    roots_f = tempfile.NamedTemporaryFile("w", suffix=".list", delete=False)
    roots_f.write("# test\n%s/root\n%s/etc\n%s/usr/local/bin\n%s/var/lib\n%s/opt\n" %
                  (root, root, root, root, root))
    roots_f.close()
    # our walk uses absolute paths from "/", so point tests at real /; instead
    # monkeypatch scanning by symlinking test root under a tmp dir is not
    # needed — this selftest inspects helper logic only.
    lines = []
    load_base("/tmp")
    # unit-ish checks
    assert prune_dir("root/node_modules") is True
    assert prune_dir("root/.cache") is True
    assert prune_dir("root/.config/app") is False
    assert prune_file("var/lib/customx/data.db") is False
    assert prune_file("usr/local/lib/node_modules/9router/cli.js") is True
    print("selftest PASS")
    sys.exit(0)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd")
    l = sub.add_parser("list")
    l.add_argument("--roots", required=True)
    l.add_argument("--out", required=True)
    l.add_argument("--base", default="/tmp")
    l.add_argument("--stats")
    sub.add_parser("selftest")
    args = ap.parse_args()
    if args.cmd == "list":
        collect(args.roots, args.out, args.base, args.stats)
    elif args.cmd == "selftest":
        selftest()
    else:
        ap.print_help()
        sys.exit(2)


if __name__ == "__main__":
    main()
