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
    # "usr/local/share/uv",  # REMOVED v5.5 - hermes venv به uv وابسته است (symlink) باید بماند
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


# v6.26: OpenClaw — داده‌ی کاربر باید کامل بماند، کد بازنصب می‌شود.
# /root/.openclaw شامل agents/ (سشن‌ها و حافظه)، workspace/ و openclaw.json است.
# داخل آن پوشه‌هایی به نام cache/tmp/logs و حتی node_modules (پلاگین‌ها و skillها)
# وجود دارد که با قواعد عمومی prune حذف می‌شدند؛ این‌ها را استثنا می‌کنیم مگر
# آن‌هایی که واقعاً دور‌ریختنی‌اند.
#
# v6.36 (حادثهٔ 2026-09-17): استثنای v6.26 بی‌قید بود و *هر* چیزی زیر .openclaw
# را نگه می‌داشت — از جمله .git یک پروژهٔ استخراج‌شده که خود ایجنت ساخته بود.
# اعتبارسنجِ پیش از آپلود چنین استثنایی نداشت، پس آرشیو مردود می‌شد و ذخیره‌سازی
# کاملاً متوقف شد (≈۹ ساعت داده از دست رفت). درمان دو لایه دارد:
#   1) همین‌جا: نام‌های واقعاً دورریختنی حتی زیر .openclaw هم prune می‌شوند.
#   2) validate(): دیگر قواعد را دوباره پیاده‌سازی نمی‌کند، بلکه *همین* توابع را
#      صدا می‌زند؛ پس تناقض جمع‌آورنده/اعتبارسنج از نظر ساختاری ناممکن می‌شود.
# نکته: node_modules زیر .openclaw عمداً نگه داشته می‌شود (پلاگین‌ها و skillها
# با آن کار می‌کنند و چیزی آن‌ها را بازنصب نمی‌کند) — و چون اعتبارسنج از همین
# تابع استفاده می‌کند، نگه‌داشتنش دیگر بی‌خطر است.
_OPENCLAW_DATA = "root/.openclaw"
_OPENCLAW_DROP = (
    "root/.openclaw/cache",
    "root/.openclaw/tmp",
    "root/.openclaw/media",   # فایل‌های حجیم رسانه‌ای؛ در صورت نیاز دوباره ساخته می‌شوند
)
# نام پوشه‌هایی که حتی داخل دادهٔ OpenClaw هم دورریختنی‌اند (هر عمقی).
# .git عمداً اینجاست: ایجنت مرتب مخزن clone/extract می‌کند و تاریخچهٔ git
# نه دادهٔ سشن است نه بازسازی‌ناپذیر — ولی آرشیو را مسموم می‌کرد.
_OPENCLAW_DROP_NAMES = {
    ".git", "__pycache__", ".cache", ".npm", ".nvm", ".bun",
    ".pytest_cache", ".mypy_cache", ".tox", ".nox", ".gradle",
    ".nuget", ".conda", ".venv", "venv", "Trash",
}


def _under_openclaw(rel):
    return rel == _OPENCLAW_DATA or rel.startswith(_OPENCLAW_DATA + "/")


def _openclaw_drop(rel):
    """True اگر مسیرِ زیر .openclaw دورریختنی است (باید prune شود)."""
    for d in _OPENCLAW_DROP:
        if rel == d or rel.startswith(d + "/"):
            return True
    # segmentهای بعد از 'root/.openclaw'
    segs = rel.split("/")[2:]
    return any(s in _OPENCLAW_DROP_NAMES for s in segs)


def _openclaw_keep(rel):
    """True اگر مسیر زیر دادهٔ OpenClaw است و باید علیرغم نام عمومی حفظ شود."""
    if not _under_openclaw(rel):
        return False
    return not _openclaw_drop(rel)


def _in_site_packages(rel):
    """v6.39: آیا مسیر داخل درخت پکیج‌های نصب‌شدهٔ پایتون است؟

    داخل site-packages/dist-packages نام پوشه معنای «کش» نمی‌دهد؛
    زیرماژول واقعی است (headroom/cache, urllib3/contrib/tmp, ...).
    """
    return "/site-packages/" in rel or "/dist-packages/" in rel


def prune_dir(rel):
    # v6.39: __pycache__ همیشه دورریختنی است — این بررسی باید *قبل* از هر
    # معافیتی بیاید، وگرنه معافیت venv هرمس آن را هم نگه می‌دارد (حجم اضافه).
    if rel.rstrip("/").rsplit("/", 1)[-1] == "__pycache__":
        return True
    # v5.3: hermes-agent venv must persist (gateway needs it), so exempt it from venv prune
    if rel.startswith("usr/local/lib/hermes-agent/venv") or rel.startswith("usr/local/lib/hermes-agent/.venv"):
        return False
    if rel == "usr/local/lib/hermes-agent/venv" or rel == "usr/local/lib/hermes-agent/.venv":
        return False
    # v6.26: کد OpenClaw (رانتایم Node 24 + node_modules) هرگز آرشیو نمی‌شود —
    # حجیم است و provision.sh آن را با نسخهٔ دقیق بازنصب می‌کند (مثل 9router).
    if rel == "opt/openclaw-node" or rel.startswith("opt/openclaw-node/"):
        return True
    if rel == "opt/openclaw-app" or rel.startswith("opt/openclaw-app/"):
        return True
    # v6.36: دورریختنی‌های زیر .openclaw صریحاً prune می‌شوند (.git/cache/…)،
    # وگرنه walk داخلشان می‌رود و آرشیو در اعتبارسنجی مردود می‌شود.
    if _under_openclaw(rel):
        return _openclaw_drop(rel)
    name = rel.rstrip("/").rsplit("/", 1)[-1]
    # v6.39: مهم — داخل درخت site-packages / dist-packages، پوشه‌هایی مثل
    # cache, logs, tmp, venv, target «کش» نیستند؛ زیرپکیج واقعی پایتون‌اند.
    # حذفشان کتابخانه را خراب می‌کند. نمونهٔ واقعی: headroom/cache حذف شد و
    # سرویس با ModuleNotFoundError: No module named 'headroom.cache' وارد
    # کرش‌لوپ شد (۸۲۷ ری‌استارت). فقط __pycache__ داخل پکیج‌ها دورریختنی است.
    if _in_site_packages(rel):
        return name == "__pycache__"
    if name in PRUNE_DIR_NAMES:
        # extra check: if parent is hermes-agent, keep venv
        if "hermes-agent" in rel and name in ("venv", ".venv"):
            return False
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
    # v6.36: ژورنال زندهٔ SQLite هرگز نباید خام آرشیو شود — مستقل از اینکه
    # نام پایه چه پسوندی دارد. (نمونهٔ واقعی روی سرور: data.sqlite.fresh-bak-wal
    # که پسوند PRUNE_FILE_SUFFIXES را نداشت و از کنار همه رد می‌شد.)
    # بازیابی از یک -wal ناهماهنگ می‌تواند دیتابیس را خراب کند؛ نسخهٔ سازگار را
    # sqlite_stage.py جداگانه stage می‌کند.
    if name.endswith(("-wal", "-shm")):
        return True
    # v6.26: کد OpenClaw آرشیو نمی‌شود (بازنصب می‌شود)
    if rel.startswith("opt/openclaw-node/") or rel.startswith("opt/openclaw-app/"):
        return True
    # v6.36: فایل‌های دور‌ریختنی زیر .openclaw (cache/tmp/media/.git/…) حذف می‌شوند
    if _under_openclaw(rel):
        if _openclaw_drop(rel):
            return True
        # بقیهٔ فایل‌های دادهٔ OpenClaw می‌مانند؛ فقط موارد گذرا حذف می‌شوند.
        # -wal/-shm ژورنال‌های زندهٔ SQLite‌اند و هرگز نباید خام آرشیو شوند
        # (خود دیتابیس توسط sqlite_stage.py سازگار snapshot می‌شود).
        return name.endswith((".sock", ".pid", ".lock", ".log",
                              "-wal", "-shm",
                              ".sqlite-wal", ".sqlite-shm",
                              ".db-wal", ".db-shm"))
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


def member_violation(rel, kind=None):
    """سیاست واحد: آیا این عضوِ آرشیو *نباید* آنجا می‌بود؟

    v6.36 — این تابع دیگر قواعد prune را دوباره پیاده‌سازی نمی‌کند؛ عیناً همان
    prune_dir()/prune_file() جمع‌آورنده را صدا می‌زند. هر استثنایی که به
    جمع‌آورنده اضافه شود خودبه‌خود در اعتبارسنجی هم اعمال می‌شود، پس حالتی که
    جمع‌آورنده «نگه دار» بگوید و اعتبارسنج «ممنوع» — یعنی دقیقاً باگی که در
    2026-09-17 همهٔ ذخیره‌سازی‌ها را متوقف کرد — از نظر ساختاری ناممکن است.

    تشخیص نوع عضو (مهم): یک نام ممکن است به‌عنوان پوشه مجاز و به‌عنوان فایل
    ممنوع باشد (یا برعکس) — مثلاً فایلی به نام «cache» یا پوشه‌ای به نام
    «x.log». پس نوع را با اولویت زیر تعیین می‌کنیم:
      1) kind صریح ("d"/"f")
      2) اسلشِ پایانی — خروجی `tar -tzf` پوشه‌ها را این‌طور نشان می‌دهد
      3) وضعیت واقعی روی دیسک
      4) اگر هیچ‌کدام: محافظه‌کار عمل کن و فقط وقتی مردود کن که در هر دو
         حالت ممنوع باشد (هرگز چیزی را که جمع‌آورنده نگه داشته رد نکن)
    خروجی: None یعنی مجاز، وگرنه رشتهٔ دلیل.
    """
    clean = rel.rstrip("/")
    if kind is None:
        if rel.endswith("/"):
            kind = "d"
        else:
            try:
                if os.path.islink("/" + clean):
                    kind = "f"
                elif os.path.isdir("/" + clean):
                    kind = "d"
                elif os.path.exists("/" + clean):
                    kind = "f"
            except OSError:
                kind = None
    # هر جدّ مسیر اگر prune می‌شد، فرزندش هرگز نباید داخل آرشیو باشد.
    parts = clean.split("/")
    for i in range(1, len(parts)):
        anc = "/".join(parts[:i])
        if prune_dir(anc):
            return f"under-pruned-dir:{anc}"
    # ژورنال زندهٔ SQLite هرگز مجاز نیست — مستقل از نوع عضو. (بازیابی از یک
    # -wal ناهماهنگ می‌تواند دیتابیس را خراب کند؛ sqlite_stage.py نسخهٔ سازگار
    # را جداگانه stage می‌کند.)
    if clean.endswith(("-wal", "-shm")):
        return "sqlite-journal"
    if kind == "d":
        return "pruned-dir" if prune_dir(clean) else None
    if kind == "f":
        return "pruned-file" if prune_file(clean) else None
    # نوع نامعلوم (عضوی که دیگر روی دیسک نیست): محافظه‌کارانه
    if prune_dir(clean) and prune_file(clean):
        return "pruned-entry"
    return None


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
            why = member_violation(rel.rstrip("/"))
            if why:
                bad.append((rel, why))
    print(f"[validate] members_total={total} payload_members={payload}")
    if bad:
        print(f"[validate] FAIL: {len(bad)} forbidden member(s) found (first 30):")
        for rel, why in bad[:30]:
            print(f"    {why:28} {rel}")
        sys.exit(1)
    if payload == 0:
        print("[validate] FAIL: archive contains no payload members")
        sys.exit(1)
    print(f"[validate] PASS (total={total} payload={payload})")


def prune_list(members_file):
    """v6.36 — «خودترمیمی»: به‌جای مردودکردن کل آرشیو، فقط سطرهای متخلف را از
    لیست حذف می‌کند و تعداد حذف‌شده‌ها را روی stderr گزارش می‌دهد.

    فلسفه: از دست رفتن چند فایلِ دورریختنی بی‌نهایت بهتر از توقف کاملِ بکاپ و
    نابودی سشن‌های کاربر است. save.sh این را قبل از tar اجرا می‌کند تا آرشیو
    از اساس تمیز ساخته شود.
    """
    kept, dropped = [], []
    with open(members_file, "r", encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            rel = raw.strip()
            if not rel:
                continue
            if member_violation(rel.rstrip("/")):
                dropped.append(rel)
            else:
                kept.append(rel)
    with open(members_file, "w", encoding="utf-8") as fh:
        for rel in kept:
            fh.write(rel + "\n")
    if dropped:
        print(f"[prune-list] removed {len(dropped)} forbidden entr(ies) "
              f"before archiving (first 20):", file=sys.stderr)
        for rel in dropped[:20]:
            print(f"    {rel}", file=sys.stderr)
    print(f"[prune-list] kept={len(kept)} dropped={len(dropped)}")


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
    # ---- v6.36 regression tests: حادثهٔ 2026-09-17 (از دست رفتن سشن OpenClaw)
    # مسیر دقیقی که رانر #148 را شکست داد:
    _POISON = ("root/.openclaw/workspace/backups/live-20260916-2245/us/"
               "mirza-pro-extracted/mirza_pro/.git")
    assert prune_dir(_POISON) is True, "‌.git زیر .openclaw باید prune شود"
    assert member_violation(_POISON + "/hooks/pre-commit.sample") is not None
    assert prune_dir("root/.openclaw/.git") is True
    assert prune_dir("root/.openclaw/workspace/proj/__pycache__") is True
    # دادهٔ واقعی کاربر باید دست‌نخورده بماند:
    assert prune_dir("root/.openclaw/agents/main") is False
    assert prune_dir("root/.openclaw/workspace") is False
    assert prune_dir("root/.openclaw/workspace/skills/my/node_modules") is False
    assert prune_file("root/.openclaw/openclaw.json") is False
    assert member_violation("root/.openclaw/agents/main/agent/"
                            "openclaw-agent.sqlite") is None
    assert member_violation("root/.openclaw/workspace/skills/my/"
                            "node_modules/x/index.js") is None
    # قرارداد اصلی: هر چیزی که جمع‌آورنده نگه می‌دارد، اعتبارسنج هم باید بپذیرد.
    for _p in ("root/.openclaw/agents/main/memory.json",
               "root/.openclaw/workspace/notes/todo.md",
               "root/.hermes/skills/a/skill.py",
               "usr/local/lib/hermes-agent/venv/bin/python"):
        assert member_violation(_p) is None, f"collector/validator mismatch: {_p}"
    # و هر چیزی که prune می‌شود، اعتبارسنج هم باید رد کند.
    for _p in ("root/node_modules/pkg/index.js",
               "root/.cache/x/y",
               "root/.openclaw/cache/blob.bin",
               "root/.openclaw/tmp/scratch"):
        assert member_violation(_p) is not None, f"validator too permissive: {_p}"
    # Hermes همچنان طبق قواعد عمومی prune می‌شود (استثنای OpenClaw ندارد)
    assert prune_dir("root/.hermes/.git") is True
    assert prune_dir("root/.hermes/skills/x/node_modules") is True

    # ژورنال SQLite با نام پایهٔ غیرمتعارف (نمونهٔ واقعی روی سرور، v6.36):
    # قبلاً جمع‌آورنده نگهش می‌داشت ولی اعتبارسنج ردش می‌کرد — همان الگوی باگ اصلی.
    for _j in ("root/.9router/db/data.sqlite.fresh-bak-wal",
               "root/.9router/db/data.sqlite.prepwfix-shm",
               "root/.openclaw/state/openclaw.sqlite-wal"):
        assert prune_file(_j) is True, f"journal not pruned: {_j}"
        assert member_violation(_j, "f") is not None

    # ---- قرارداد سراسری: جمع‌آورنده و اعتبارسنج هرگز نباید اختلاف داشته باشند.
    # این حلقه همان کلاس باگی را می‌گیرد که حادثه را ساخت، برای *هر* مسیری.
    _probe = [
        "root/.openclaw", "root/.openclaw/openclaw.json",
        "root/.openclaw/agents/main/agent/openclaw-agent.sqlite",
        "root/.openclaw/agents/main/memory/notes.md",
        "root/.openclaw/workspace/a/.git/config",
        "root/.openclaw/workspace/a/node_modules/p/i.js",
        "root/.openclaw/workspace/a/__pycache__/m.pyc",
        "root/.openclaw/cache/x", "root/.openclaw/tmp/y",
        "root/.openclaw/logs/app.txt",
        "root/.hermes/.env", "root/.hermes/skills/s/main.py",
        "root/.hermes/.git/HEAD", "root/.hermes/x/node_modules/a.js",
        "usr/local/lib/hermes-agent/venv/bin/python",
        "root/.9router/db/data.sqlite", "root/.cache/z",
        "var/lib/customx/data.db", "etc/app/conf.ini",
    ]
    def _collector_would_archive(rel, kind):
        """بازتولید تصمیم واقعی walk_abs(): اگر هر جدّی prune شود، عضو هرگز
        وارد آرشیو نمی‌شود — حتی اگر prune_file() تنهایی False بدهد."""
        parts = rel.split("/")
        for i in range(1, len(parts)):
            if prune_dir("/".join(parts[:i])):
                return False
        return not (prune_dir(rel) if kind == "d" else prune_file(rel))

    for _p in _probe:
        for _k in ("f", "d"):
            _archived = _collector_would_archive(_p, _k)
            _rejected = member_violation(_p, _k) is not None
            assert _archived != _rejected, (
                f"collector/validator DISAGREE on {_p} (kind={_k}): "
                f"collector_archives={_archived} validator_rejects={_rejected}")

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
    p = sub.add_parser("prune-list",
                       help="v6.36: strip forbidden entries from a member list "
                            "in place (self-heal instead of failing the save)")
    p.add_argument("--members", required=True)
    sub.add_parser("selftest")
    args = ap.parse_args()
    if args.cmd == "list":
        collect(args.roots, args.out, args.base, args.stats, args.keepbig)
    elif args.cmd == "validate":
        validate(args.members)
    elif args.cmd == "prune-list":
        prune_list(args.members)
    elif args.cmd == "selftest":
        selftest()
    else:
        ap.print_help()
        sys.exit(2)


if __name__ == "__main__":
    main()




