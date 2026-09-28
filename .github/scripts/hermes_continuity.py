#!/usr/bin/env python3
"""Verified, small continuity archives for Hermes conversation state.

The general server snapshot is intentionally broad and can be large. This
utility captures only Hermes state that determines conversation continuity:
SQLite session stores (including named profiles), compact memories, config and
the legacy routing mirror. Each database is copied with SQLite's online-backup
API, then checked before it is packed. Restore verifies every digest and every
SQLite database before atomically replacing files.

This module does not upload anything. hermes_continuity.sh handles the
repository transport through state_sync.py.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import sys
import tarfile
import tempfile
from urllib.parse import quote

SCHEMA = 1
SKIP_PARTS = {".git", "cache", ".cache", "logs", "tmp", "venv", ".venv", "node_modules", "hermes-agent"}
DB_NAMES = {"state.db", "kanban.db"}
EXTRA_NAMES = {"config.yaml", "sessions.json", "MEMORY.md", "USER.md"}


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        while True:
            block = fh.read(1024 * 1024)
            if not block:
                return h.hexdigest()
            h.update(block)


def is_candidate(path: Path, home: Path) -> bool:
    try:
        rel = path.relative_to(home)
    except ValueError:
        return False
    if any(part in SKIP_PARTS for part in rel.parts):
        return False
    if path.name in DB_NAMES:
        return True
    if path.name == "config.yaml":
        return True
    if path.name == "sessions.json" and path.parent.name == "sessions":
        return True
    if path.name in {"MEMORY.md", "USER.md"} and path.parent.name == "memories":
        return True
    return False


def discover(home: Path) -> list[Path]:
    if not home.is_dir():
        return []
    out: list[Path] = []
    for p in home.rglob("*"):
        try:
            if p.is_file() and not p.is_symlink() and is_candidate(p, home):
                out.append(p)
        except OSError:
            continue
    # A database is the minimum meaningful continuity payload. Do not silently
    # create an archive which only has config/memory files.
    if not any(p.name == "state.db" for p in out):
        raise RuntimeError(f"no Hermes state.db found under {home}")
    return sorted(set(out), key=lambda p: str(p))


def sqlite_snapshot(src: Path, dst: Path) -> dict:
    """Create and verify a WAL-aware consistent SQLite copy."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    uri = "file:" + quote(str(src)) + "?mode=ro"
    source = sqlite3.connect(uri, uri=True, timeout=15)
    try:
        target = sqlite3.connect(dst, timeout=15)
        try:
            source.backup(target)
        finally:
            target.close()
    finally:
        source.close()
    return db_stats(dst)


def db_stats(path: Path) -> dict:
    uri = "file:" + quote(str(path)) + "?mode=ro"
    con = sqlite3.connect(uri, uri=True, timeout=15)
    try:
        integrity = con.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            raise RuntimeError(f"integrity_check for {path} returned {integrity!r}")
        tables = {row[0] for row in con.execute(
            "SELECT name FROM sqlite_master WHERE type='table'")}
        info: dict[str, object] = {"integrity": integrity, "tables": sorted(tables)}
        for table in ("sessions", "messages"):
            if table in tables:
                info[table] = int(con.execute(f"SELECT count(*) FROM {table}").fetchone()[0])
        if "sessions" in tables:
            by_source = con.execute(
                "SELECT COALESCE(source, ''), count(*) FROM sessions GROUP BY source ORDER BY source"
            ).fetchall()
            info["sessions_by_source"] = {str(k): int(v) for k, v in by_source}
        return info
    finally:
        con.close()


def live_fingerprint(home: Path) -> str:
    """Cheap change detector including SQLite WAL state, without reading data."""
    home = home.resolve()
    files = discover(home)
    rows: list[str] = []
    for path in files:
        rel = path.relative_to(home).as_posix()
        # SQLite can checkpoint a write without changing an easily observable
        # mtime on every filesystem. Hashing only this compact state set is the
        # reliable change detector; it is still far cheaper than packaging or
        # uploading the general 1.7GB server archive.
        rows.append(f"{rel}\t{path.stat().st_size}\t{sha256(path)}")
        if path.name == "state.db":
            for suffix in ("-wal", "-shm"):
                aux = Path(str(path) + suffix)
                if aux.exists():
                    rows.append(f"{rel}{suffix}\t{aux.stat().st_size}\t{sha256(aux)}")
                else:
                    rows.append(f"{rel}{suffix}\t-")
    return hashlib.sha256("\n".join(sorted(rows)).encode("utf-8")).hexdigest()


def make_archive(home: Path, out: Path, handoff: bool = False) -> dict:
    home = home.resolve()
    files = discover(home)
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="hermes-continuity-") as td:
        stage = Path(td) / "payload"
        members: list[dict] = []
        for source in files:
            rel = source.relative_to(home).as_posix()
            target = stage / rel
            if source.name in DB_NAMES:
                info = sqlite_snapshot(source, target)
                kind = "sqlite"
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
                info = {}
                kind = "file"
            members.append({
                "path": rel,
                "kind": kind,
                "bytes": target.stat().st_size,
                "sha256": sha256(target),
                "sqlite": info,
            })
        manifest = {
            "schema": SCHEMA,
            "created_at": utc_now(),
            "handoff": bool(handoff),
            "home": str(home),
            "members": members,
        }
        manifest_path = Path(td) / "manifest.json"
        manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
                                 encoding="utf-8")
        temporary = out.with_name(out.name + f".tmp-{os.getpid()}")
        try:
            with tarfile.open(temporary, "w:gz", compresslevel=1) as tf:
                for member in members:
                    tf.add(stage / member["path"], arcname="payload/" + member["path"], recursive=False)
                tf.add(manifest_path, arcname="manifest.json", recursive=False)
            os.replace(temporary, out)
        finally:
            temporary.unlink(missing_ok=True)
    # Validate the newly-created archive through the exact same reader used by restore.
    return validate_archive(out)


def _safe_member(name: str) -> bool:
    p = Path(name)
    return not p.is_absolute() and ".." not in p.parts and name != ""


def _load_archive(archive: Path, extract_to: Path | None = None) -> dict:
    if not archive.is_file() or archive.stat().st_size == 0:
        raise RuntimeError(f"archive missing or empty: {archive}")
    with tarfile.open(archive, "r:gz") as tf:
        all_members = tf.getmembers()
        by_name = {m.name: m for m in all_members}
        man = by_name.get("manifest.json")
        if not man or not man.isfile():
            raise RuntimeError("manifest.json missing from continuity archive")
        try:
            manifest = json.loads(tf.extractfile(man).read().decode("utf-8"))
        except Exception as exc:  # noqa: BLE001
            raise RuntimeError(f"cannot parse continuity manifest: {exc}") from exc
        if manifest.get("schema") != SCHEMA or not isinstance(manifest.get("members"), list):
            raise RuntimeError("unsupported or malformed continuity manifest")
        wanted = {"manifest.json"}
        for row in manifest["members"]:
            if not isinstance(row, dict) or not isinstance(row.get("path"), str):
                raise RuntimeError("malformed continuity member")
            rel = row["path"]
            if not _safe_member(rel):
                raise RuntimeError(f"unsafe continuity path: {rel!r}")
            name = "payload/" + rel
            wanted.add(name)
            m = by_name.get(name)
            if not m or not m.isfile() or m.issym() or m.islnk():
                raise RuntimeError(f"missing or unsafe member: {name}")
        names = {m.name for m in all_members}
        if names != wanted:
            raise RuntimeError("archive has unexpected or missing members")
        if extract_to is not None:
            for row in manifest["members"]:
                rel = row["path"]
                out = extract_to / "payload" / rel
                out.parent.mkdir(parents=True, exist_ok=True)
                src = tf.extractfile("payload/" + rel)
                if src is None:
                    raise RuntimeError(f"cannot read {rel}")
                with out.open("wb") as dst:
                    shutil.copyfileobj(src, dst)
                expected = row.get("sha256")
                if not isinstance(expected, str) or sha256(out) != expected:
                    raise RuntimeError(f"digest mismatch: {rel}")
                if row.get("kind") == "sqlite":
                    actual = db_stats(out)
                    claimed = row.get("sqlite") or {}
                    for key in ("integrity", "sessions", "messages", "sessions_by_source"):
                        if key in claimed and actual.get(key) != claimed.get(key):
                            raise RuntimeError(f"SQLite stats mismatch for {rel}: {key}")
    return manifest


def validate_archive(archive: Path) -> dict:
    with tempfile.TemporaryDirectory(prefix="hermes-continuity-verify-") as td:
        manifest = _load_archive(archive, Path(td))
    dbs = [r for r in manifest["members"] if r.get("kind") == "sqlite"]
    return {
        "created_at": manifest.get("created_at"),
        "handoff": bool(manifest.get("handoff")),
        "members": len(manifest["members"]),
        "databases": len(dbs),
        "message_count": sum(int((r.get("sqlite") or {}).get("messages", 0)) for r in dbs),
        "sha256": sha256(archive),
        "bytes": archive.stat().st_size,
    }


def restore_archive(home: Path, archive: Path, marker: Path | None = None) -> dict:
    home = home.resolve()
    with tempfile.TemporaryDirectory(prefix="hermes-continuity-restore-") as td:
        staged = Path(td)
        manifest = _load_archive(archive, staged)
        # Validation completed before touching the live state. Replace files one at
        # a time with os.replace, removing WAL/SHM only after the matching main DB
        # has been atomically installed. Services must be stopped by the caller.
        for row in manifest["members"]:
            rel = row["path"]
            source = staged / "payload" / rel
            dest = home / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            replacement = dest.with_name(f".{dest.name}.continuity-{os.getpid()}")
            shutil.copy2(source, replacement)
            os.replace(replacement, dest)
            if row.get("kind") == "sqlite":
                Path(str(dest) + "-wal").unlink(missing_ok=True)
                Path(str(dest) + "-shm").unlink(missing_ok=True)
    result = validate_archive(archive)
    result.update({"restored_at": utc_now(), "home": str(home)})
    if marker:
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        os.chmod(marker, 0o600)
    return result


def selftest() -> None:
    with tempfile.TemporaryDirectory(prefix="hermes-continuity-selftest-") as td:
        base = Path(td)
        source = base / "source"
        (source / "memories").mkdir(parents=True)
        (source / "memories" / "MEMORY.md").write_text("test memory\n", encoding="utf-8")
        (source / "memories" / "USER.md").write_text("test user\n", encoding="utf-8")
        (source / "sessions").mkdir()
        (source / "sessions" / "sessions.json").write_text("{}\n", encoding="utf-8")
        (source / "config.yaml").write_text("memory:\n  memory_enabled: true\n", encoding="utf-8")
        db = source / "state.db"
        c = sqlite3.connect(db)
        c.execute("create table sessions (id text, source text)")
        c.execute("create table messages (id integer, body text)")
        c.execute("insert into sessions values ('s1', 'telegram')")
        c.execute("insert into messages values (1, 'not exposed in logs')")
        c.commit(); c.close()
        archive = base / "continuity.tar.gz"
        info = make_archive(source, archive, handoff=True)
        assert info["message_count"] == 1 and info["handoff"]
        target = base / "target"
        result = restore_archive(target, archive, base / "marker.json")
        con = sqlite3.connect(target / "state.db")
        assert con.execute("select count(*) from messages").fetchone()[0] == 1
        con.close()
        assert (target / "memories" / "MEMORY.md").read_text(encoding="utf-8") == "test memory\n"
        assert result["databases"] == 1
    print("hermes continuity selftest: PASS")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    p_ck = sub.add_parser("checkpoint")
    p_ck.add_argument("--home", default="/root/.hermes")
    p_ck.add_argument("--out", required=True)
    p_ck.add_argument("--handoff", action="store_true")
    p_val = sub.add_parser("validate")
    p_val.add_argument("--archive", required=True)
    p_re = sub.add_parser("restore")
    p_re.add_argument("--home", default="/root/.hermes")
    p_re.add_argument("--archive", required=True)
    p_re.add_argument("--marker", default="/var/lib/hermes-continuity/last-restore.json")
    p_fp = sub.add_parser("fingerprint")
    p_fp.add_argument("--home", default="/root/.hermes")
    sub.add_parser("selftest")
    args = parser.parse_args()
    try:
        if args.command == "checkpoint":
            result = make_archive(Path(args.home), Path(args.out), args.handoff)
        elif args.command == "validate":
            result = validate_archive(Path(args.archive))
        elif args.command == "restore":
            result = restore_archive(Path(args.home), Path(args.archive), Path(args.marker))
        elif args.command == "fingerprint":
            print(live_fingerprint(Path(args.home)))
            return 0
        else:
            selftest()
            return 0
        print(json.dumps(result, ensure_ascii=False, sort_keys=True))
        return 0
    except Exception as exc:  # noqa: BLE001
        print(f"hermes continuity: ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
