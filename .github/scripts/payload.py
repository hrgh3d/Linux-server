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
                  [--keepbig /path/payload_keepbig.list]
  payload.py validate --members /tmp/state.members
  payload.py selftest
"""
import argparse
import json
import os
import stat
import sys

# Directory names skipped wherever they appear (any depth). "cache" is a
# generic cache dir name; adding it here removes image/package cache residue
# that would otherwise creep in (e.g. /root/.config/.android/cache). Only
# real data lives in dirs that are NOT named as caches.
PRUNE_DIR_NAMES = {
    ".cache", "cache", "__pycache__", ".git", ".npm", ".nvm", ".bun",
    ".rustup", ".cargo", ".dotnet", ".pip", ".venv", "venv", "node_modules",
    "hostedtoolcache", "containerd", "target", ".pytest_cache",
    ".mypy_cache", ".tox", ".nox", ".gradle", ".nuget", ".conda",
    "audio_cache", "image_cache", "video_cache", "browser_cache",
    "logs", "tmp", "Trash",
}

# File names / suffixes skipped anywhere.
PRUNE_FILE_NAMES = {
    ".bash_history", ".zsh_history", ".wget-hsts", ".lesshst",
    "derpmap.cached.json",
    # transient x-ui / app-generated files that are recreated on demand and
    # would otherwise dirty the archive (install metadata + runtime metrics)
    "install-result.env", "system_metrics.gob",
}
# sqlite -wal/-shm are transient journal/aux files of a live database; the db
# itself is snapshotted consistently (sqlite_stage.py) so these must never be
# archived raw.
PRUNE_FILE_SUFFIXES = (".sock", ".pid", ".lock", ".pyc", ".log", ".tmp",
                       ".db-wal", ".db-shm", ".sqlite-wal", ".sqlite-shm")

# Default per-file size cap (override with env PAYLOAD_MAX_FILE_BYTES). Files
# larger than this are treated as package binaries/runtime and reinstalled
# with the package — EXCEPT under directories listed in --keepbig (user data).
MAX_FILE_BYTES = int(os.environ.get("PAYLOAD_MAX_FILE_BYTES", 32 * 1024 * 1024))
_BIG_KEEP = []          # rel prefixes exempt from the size cap (--keepbig)
_SKIPPED_BIG = []       # (bytes, rel) files dropped by the size cap

# Absolute code/install trees -> reinstalled from catalog, not backed up.
# NOTE: root/.hermes/skills is deliberately NOT pruned: users may add or edit
# skills and those must survive a restore (merged over a fresh install).
PRUNE_ABS_DIRS = [
    "usr/local/lib/node_modules",
    # "usr/local/lib/hermes-agent",  # REMOVED v4.5.2 - باید بین ران‌ها بماند تا gateway کار کند (Mode 2)
    "usr/local/share/uv",
    "usr/local/x-ui/bin",
    # v5.2: runner image bulk - never persist (android SDK 7GB caused snapshot timeout)
    "usr/local/lib/android",
    "usr/local/lib/heroku",
    # v4.5: root/.hermes/bin (cloudflared etc) را دیگر prune نمی‌کنیم تا بین ران‌ها پاک نشود (درخواست کاربر)
    # "root/.hermes/bin",  # REMOVED - cloudflared باید بماند
    # "root/.hermes/hermes-agent",  # REMOVED - برای حالت Mode 2 خالص
    # image-build residue under /root (never user data): cache/module stores
    # that the hosted image created while provisioning as root
    "root/.launchpadlib",
    "root/.local/share/powershell",
    "root/.rpmdb",
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

_BASE = {"usr/local/bin": set(), "usr/local/sbin": set(), "opt": set(),
         "var/lib": set()}

# files skipped by the size cap: (bytes, rel)
_SKIPPED_BIG = []


def load_base(base_dir):
    mapping = {
        "usr/local/bin": os.path.join(base_dir, "base_usrlocalbin.list"),
        "usr/local/sbin": os.path.join(base_dir, "base_usrlocalsbin.list"),
        "opt": os.path.join(base_dir, "base_opt_entries.list"),
        "var/lib": os.path.join(base_dir, "base_varlib_entries.list"),
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


def load_keepbig(path):
    """Prefixes (rel dirs) whose large files are real user data -> no size cap."""
    _BIG_KEEP.clear()
    if not path or not os.path.isfile(path):
        return
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            p = line.strip().rstrip("/")
            if p and not p.startswith("#"):
                _BIG_KEEP.append(p)


def big_keep_under(rel):
    return any(rel == p or rel.startswith(p + "/") for p in _BIG_KEEP)


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
            if stat.S_ISREG(st.st_mode) and st.st_size > MAX_FILE_BYTES \
                    and not big_keep_under(rel):
                _SKIPPED_BIG.append((st.st_size, rel))
                continue
            if prune_file(rel):
                continue
            members.add((rel, "l" if stat.S_ISLNK(st.st_mode) else "f"))


def collect(root_file, out_file, base_dir, stats_file=None, keepbig_file=None):
    load_base(base_dir)
    load_keepbig(keepbig_file)
    roots = []
    with open(root_file, "r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if os.path.isdir(line):
                roots.append(line)
    global _SKIPPED_BIG
    _SKIPPED_BIG = []
    members = set()  # (rel, kind)
    for root in roots:
        walk_abs(root, members)

    # visible warning for every file dropped by the size cap (not silent)
    big_total = sum(sz for sz, _ in _SKIPPED_BIG)
    for sz, rel in sorted(_SKIPPED_BIG, reverse=True)[:50]:
        print(f"[payload] WARN big-file-skip size={sz} rel={rel}", flush=True)
    if _SKIPPED_BIG:
        print(f"[payload] WARN {len(_SKIPPED_BIG)} file(s) over {MAX_FILE_BYTES} B "
              f"skipped ({big_total/1048576:.1f} MB total). To keep them, add the "
              f"parent dir to payload_keepbig.list or raise PAYLOAD_MAX_FILE_BYTES.",
              flush=True)

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
    big = []
    for rel, kind in members:
        counts[kind] += 1
        if kind == "f":
            try:
                sz = os.path.getsize("/" + rel)
                counts["bytes"] += sz
                big.append((sz, rel))
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
                "big": sorted(big, key=lambda x: -x[0])[:10],
                "skipped_big": sorted(_SKIPPED_BIG, reverse=True)[:10],
                "skipped_big_total_bytes": sum(sz for sz, _ in _SKIPPED_BIG),
            }, fh, indent=2)
    print(f"[payload] roots={len(roots)} members={len(members)} "
          f"dirs={counts['d']} files={counts['f']} links={counts['l']} "
          f"bytes={counts['bytes']} ({counts['bytes']/1048576:.1f} MB) "
          f"big_skipped={len(_SKIPPED_BIG)}")


def validate(members_file):
    """Pre-upload archive validation: ensure nothing that was supposed to be
    pruned actually made it into the archive member list."""
    bad = []
    total = 0
    payload = 0
    with open(members_file, "r", encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            rel = raw.strip()
            if not rel:
                continue
            total += 1
            if rel.startswith("_meta/"):
                continue
            payload += 1
            clean = rel.rstrip("/")
            name = clean.rsplit("/", 1)[-1]
            if name in PRUNE_FILE_NAMES or name.endswith(PRUNE_FILE_SUFFIXES):
                bad.append((rel, "pruned-file"))
                continue
            if clean in PRUNE_ABS_FILES or \
                    any(clean == d or clean.startswith(d + "/") for d in PRUNE_ABS_DIRS):
                bad.append((rel, "pruned-abs"))
                continue
            segs = clean.split("/")
            if any(s in PRUNE_DIR_NAMES for s in segs):
                bad.append((rel, "pruned-dir-name"))
                continue
            if clean.startswith("etc/"):
                if clean in PRUNE_ETC or any(
                        clean == d or clean.startswith(d + "/") for d in PRUNE_ETC):
                    bad.append((rel, "pruned-etc"))
                    continue
            if clean.startswith("var/lib/"):
                if clean in PRUNE_VARLIB or any(
                        clean == d or clean.startswith(d + "/") for d in PRUNE_VARLIB):
                    bad.append((rel, "pruned-varlib"))
                    continue
            if clean.endswith(".db-wal") or clean.endswith(".db-shm") or \
                    clean.endswith(".sqlite-wal") or clean.endswith(".sqlite-shm"):
                bad.append((rel, "sqlite-journal"))
                continue
    print(f"[validate] members_total={total} payload_members={payload}")
    if bad:
        print(f"[validate] FAIL: {len(bad)} forbidden member(s) found (first 30):")
        for rel, why in bad[:30]:
            print(f"    {why:18} {rel}")
        sys.exit(1)
    if payload == 0:
        print("[validate] FAIL: archive contains no payload members")
        sys.exit(1)
    print("[validate] PASS")


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
    load_keepbig(None)
    # unit-ish checks
    assert prune_dir("root/node_modules") is True
    assert prune_dir("root/.cache") is True
    assert prune_dir("root/.config/app") is False
    assert prune_dir("root/.launchpadlib") is True
    assert prune_dir("root/.local/share/powershell") is True
    assert prune_dir("root/.rpmdb") is True
    assert prune_dir("root/.config/.android/cache") is True
    # user-created/edited skills must NOT be pruned
    assert prune_dir("root/.hermes/skills") is False
    assert prune_dir("root/.hermes/bin") is False  # v4.5: keep cloudflared
    assert prune_file("var/lib/customx/data.db") is False
    assert prune_file("usr/local/lib/node_modules/9router/cli.js") is True
    assert prune_file("etc/x-ui/x-ui.db-wal") is True
    assert prune_file("etc/x-ui/x-ui.db-shm") is True
    assert prune_file("root/.9router/db/data.sqlite-wal") is True
    assert prune_file("etc/x-ui/install-result.env") is True
    assert prune_file("etc/x-ui/system_metrics.gob") is True
    # size-cap keep-override
    _BIG_KEEP.append("root/app-data")
    assert big_keep_under("root/app-data/big.db") is True
    assert big_keep_under("root/other/big.db") is False
    _BIG_KEEP.clear()
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
    l.add_argument("--keepbig", default=None,
                   help="file with rel-dir prefixes whose large files are user data")
    v = sub.add_parser("validate")
    v.add_argument("--members", required=True,
                   help="archive member list (one rel path per line)")
    sub.add_parser("selftest")
    args = ap.parse_args()
    if args.cmd == "list":
        collect(args.roots, args.out, args.base, args.stats, args.keepbig)
    elif args.cmd == "validate":
        validate(args.members)
    elif args.cmd == "selftest":
        selftest()
    else:
        ap.print_help()
        sys.exit(2)


if __name__ == "__main__":
    main()

