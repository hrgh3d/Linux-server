#!/usr/bin/env python3
"""sqlite_stage.py — make consistent offline copies of every live SQLite
database that is about to be archived, so the state archive never reads a
database file while it is being written (fixes torn/inconsistent db backups).

Why: x-ui and other packages keep their SQLite databases in WAL journal mode
and run all the time. Copying the raw .db during a save can capture a torn
state (and -wal/-shm are excluded from the archive). The sqlite3 online-backup
API produces a consistent snapshot even while the source is in use.

Usage:
  sqlite_stage.py <list_in> <stage_dir> <list_out> <snap_list>
                  [--fallback] [--root <path>]

  list_in   : payload member list (one rel path per line, paths relative to /)
  stage_dir : dir where consistent copies are written under the same rel path
  list_out  : list_in with every SQLite file replaced by nothing (others kept)
  snap_list : rel paths of the consistent copies (to be tar'd from stage_dir)
  --fallback: if a single db cannot be snapshotted, keep it as a raw passthrough
              (WARN) instead of failing the whole backup
  --root PATH: base path to resolve relative members against (default '/').
              Only used for local testing; production always uses '/'.

Exit: 0 on success; 1 on failure (unless --fallback absorbed the error).
"""
import os
import shutil
import sqlite3
import sys

SQLITE_MAGIC = b"SQLite format 3\x00"


def is_sqlite_file(path):
    try:
        if os.path.islink(path):
            return False
        with open(path, "rb") as fh:
            return fh.read(16) == SQLITE_MAGIC
    except OSError:
        return False


def snapshot(src_abs, dst_abs):
    """Copy a consistent snapshot of src_abs into dst_abs and verify it."""
    os.makedirs(os.path.dirname(dst_abs) or ".", exist_ok=True)
    # online backup from a read-only handle of the live db -> consistent file
    src = sqlite3.connect(f"file:{src_abs}?mode=ro", uri=True, timeout=15)
    try:
        dst = sqlite3.connect(dst_abs, timeout=15)
        try:
            src.backup(dst)
        finally:
            dst.close()
    finally:
        src.close()
    # verify the snapshot is a healthy, readable, consistent database
    chk = sqlite3.connect(dst_abs)
    try:
        row = chk.execute("PRAGMA quick_check").fetchone()
        if not row or (row[0] != "ok"):
            raise RuntimeError(f"quick_check -> {row!r}")
    finally:
        chk.close()


def main():
    args = sys.argv[1:]
    if len(args) < 4:
        print(__doc__, file=sys.stderr)
        return 2
    list_in, stage_dir, list_out, snap_list = args[0], args[1], args[2], args[3]
    fallback = False
    root = "/"
    for a in args[4:]:
        if a == "--fallback":
            fallback = True
        elif a.startswith("--root="):
            root = a.split("=", 1)[1]
    stage_dir = os.path.abspath(stage_dir)
    os.makedirs(stage_dir, exist_ok=True)

    n_db = 0
    n_pass = 0
    failed = []
    with open(list_in, "r", encoding="utf-8", errors="replace") as fhin, \
            open(list_out, "w", encoding="utf-8") as fhout, \
            open(snap_list, "w", encoding="utf-8") as fhsnap:
        for raw in fhin:
            rel = raw.strip()
            if not rel:
                continue
            abs_path = os.path.join(root, rel)
            if is_sqlite_file(abs_path):
                n_db += 1
                dst = os.path.join(stage_dir, rel)
                try:
                    snapshot(abs_path, dst)
                except Exception as e:  # noqa: BLE001
                    failed.append((rel, str(e)))
                    if fallback:
                        print(f"[sqlite] WARN snapshot failed for {rel} "
                              f"({e}) — keeping raw passthrough", flush=True)
                        fhout.write(rel + "\n")
                        continue
                    print(f"[sqlite] ERROR snapshot failed for {rel}: {e}",
                          file=sys.stderr, flush=True)
                    return 1
                fhsnap.write(rel + "\n")
                print(f"[sqlite] staged consistent copy: {rel}", flush=True)
            else:
                n_pass += 1
                fhout.write(rel + "\n")
    if failed:
        print(f"[sqlite] {len(failed)} db(s) fell back to raw passthrough",
              flush=True)
    print(f"[sqlite] staged {n_db} sqlite db(s), passthrough {n_pass} "
          f"member(s)", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
