#!/usr/bin/env python3
"""Verified continuity archives for Hermes' durable agent state.

The general server snapshot is intentionally broad and can be large. This
utility takes the fast, canonical checkpoint used at runner handoff: all
non-ephemeral state under the Hermes home plus the small, user-created Composio
state roots. Runtime caches, installers, logs and the top-level Hermes .env
remain outside this archive. SQLite files are copied with SQLite's online
backup API and every archive is verified before it can be restored.

The transport layer is hermes_continuity.sh. It uploads only to the private
state repository and never prints archive contents or credentials.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
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

SCHEMA = 2
SUPPORTED_SCHEMAS = {1, SCHEMA}

# These contain rebuildable runtime output rather than user/agent state. The
# deny-list makes future Hermes skills, profiles and Bot Mode directories
# durable without needing a new allow-list entry every time Hermes adds one.
HERMES_SKIP_PARTS = {
    ".git", "cache", ".cache", "logs", "tmp", "venv", ".venv",
    "node_modules", "hermes-agent", "bin", "backups", ".curator_backups",
    "audio_cache", "image_cache", "runtime", "desktop", "pending_messages",
    "sandboxes",
}
INTEGRATION_SKIP_PARTS = {
    ".git", "cache", ".cache", "logs", "tmp", "venv", ".venv",
    "node_modules", "bin", "local-tools-binaries", "acp-adapters", "services",
}
INTEGRATION_ROOTS = (
    ".composio",
    ".config/composio",
    ".local/share/composio",
)


@dataclass(frozen=True)
class Candidate:
    """One archived regular file and its constrained restore destination."""

    scope: str  # "hermes" or "root"
    path: str   # POSIX path relative to that scope
    source: Path


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


def _safe_path(value: str) -> bool:
    p = Path(value)
    return bool(value) and not p.is_absolute() and ".." not in p.parts


def _is_regular_file(path: Path) -> bool:
    try:
        return path.is_file() and not path.is_symlink()
    except OSError:
        return False


def _hermes_candidate(path: Path, home: Path) -> bool:
    """Return true for durable Hermes state, not process/cache noise."""
    try:
        rel = path.relative_to(home)
    except ValueError:
        return False
    if any(part in HERMES_SKIP_PARTS for part in rel.parts):
        return False
    name = path.name
    # The canonical runtime environment is handled by the persistent vault.
    # Old guard copies are also deliberately excluded so a password/token can
    # never leak into this archive by a renamed top-level .env file.
    if len(rel.parts) == 1 and name.startswith(".env"):
        return False
    if name.endswith((".lock", ".pid", ".sock", ".log", "-wal", "-shm")):
        return False
    if ".bak-" in name or name.endswith(".pre-recovery"):
        return False
    if "cache" in name.lower():
        return False
    return _is_regular_file(path)


def _integration_candidate(path: Path, root: Path) -> bool:
    """Keep integration config/auth state, never its replaceable toolchain."""
    try:
        rel = path.relative_to(root)
    except ValueError:
        return False
    if any(part in INTEGRATION_SKIP_PARTS for part in rel.parts):
        return False
    # ~/.composio/composio is the installed CLI binary, not account state.
    if root.name == ".composio" and rel == Path("composio"):
        return False
    if path.name.endswith((".lock", ".pid", ".sock", ".log")):
        return False
    return _is_regular_file(path)


def _walk(root: Path, predicate) -> list[Path]:
    if not root.is_dir():
        return []
    result: list[Path] = []
    for path in root.rglob("*"):
        try:
            if predicate(path):
                result.append(path)
        except OSError:
            continue
    return result


def discover(home: Path, root_home: Path, require_state_db: bool = True) -> list[Candidate]:
    """Discover all policy-covered state without ever reading its contents."""
    home = home.resolve()
    root_home = root_home.resolve()
    items: list[Candidate] = []
    for path in _walk(home, lambda p: _hermes_candidate(p, home)):
        items.append(Candidate("hermes", path.relative_to(home).as_posix(), path))
    for rel_root in INTEGRATION_ROOTS:
        integration_root = root_home / rel_root
        for path in _walk(integration_root, lambda p, r=integration_root: _integration_candidate(p, r)):
            # A root-scoped member is constrained to the three named integration
            # roots by _valid_root_path() on both validation and restore.
            items.append(Candidate("root", path.relative_to(root_home).as_posix(), path))
    keys = [(item.scope, item.path) for item in items]
    if len(keys) != len(set(keys)):
        raise RuntimeError("duplicate Hermes continuity member")
    if require_state_db and not any(item.scope == "hermes" and item.path == "state.db" for item in items):
        raise RuntimeError(f"no Hermes state.db found under {home}")
    return sorted(items, key=lambda item: (item.scope, item.path))


def _is_db(candidate: Candidate) -> bool:
    return candidate.source.suffix.lower() == ".db"


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
        tables = {row[0] for row in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
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


def live_fingerprint(home: Path, root_home: Path) -> str:
    """Content hash for state, including SQLite WAL state, without logging it."""
    rows: list[str] = []
    for item in discover(home, root_home):
        rows.append(f"{item.scope}\t{item.path}\t{item.source.stat().st_size}\t{sha256(item.source)}")
        if _is_db(item):
            for suffix in ("-wal", "-shm"):
                auxiliary = Path(str(item.source) + suffix)
                if auxiliary.exists() and not auxiliary.is_symlink():
                    rows.append(f"{item.scope}\t{item.path}{suffix}\t{auxiliary.stat().st_size}\t{sha256(auxiliary)}")
                else:
                    rows.append(f"{item.scope}\t{item.path}{suffix}\t-")
    return hashlib.sha256("\n".join(sorted(rows)).encode("utf-8")).hexdigest()


def _archive_name(schema: int, scope: str, path: str) -> str:
    if schema == 1:
        return "payload/" + path
    return f"payload/{scope}/{path}"


def _valid_root_path(path: str) -> bool:
    if not _safe_path(path):
        return False
    return any(path == prefix or path.startswith(prefix + "/") for prefix in INTEGRATION_ROOTS)


def _row_location(manifest: dict, row: dict) -> tuple[str, str, str]:
    """Validate a manifest row and return (scope, relative-path, tar-name)."""
    schema = manifest.get("schema")
    path = row.get("path")
    if not isinstance(path, str) or not _safe_path(path):
        raise RuntimeError("unsafe or malformed continuity path")
    if schema == 1:
        scope = "hermes"
    else:
        scope = row.get("scope")
        if scope not in {"hermes", "root"}:
            raise RuntimeError("invalid continuity member scope")
    if scope == "root" and not _valid_root_path(path):
        raise RuntimeError("root continuity member is outside approved integration roots")
    return scope, path, _archive_name(schema, scope, path)


def make_archive(home: Path, root_home: Path, out: Path, handoff: bool = False) -> dict:
    home = home.resolve()
    root_home = root_home.resolve()
    files = discover(home, root_home)
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="hermes-continuity-") as td:
        stage = Path(td) / "payload"
        members: list[dict] = []
        for item in files:
            target = stage / item.scope / item.path
            if _is_db(item):
                info = sqlite_snapshot(item.source, target)
                kind = "sqlite"
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(item.source, target)
                info = {}
                kind = "file"
            members.append({
                "scope": item.scope,
                "path": item.path,
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
            "root_home": str(root_home),
            # Schema 2 is an exact snapshot of the policy-covered files. This
            # lets restore carry intentional deletions across a new runner.
            "managed_scopes": ["hermes", "root"],
            "members": members,
        }
        manifest_path = Path(td) / "manifest.json"
        manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")
        temporary = out.with_name(out.name + f".tmp-{os.getpid()}")
        try:
            with tarfile.open(temporary, "w:gz", compresslevel=1) as tf:
                for member in members:
                    source = stage / member["scope"] / member["path"]
                    tf.add(source, arcname=_archive_name(SCHEMA, member["scope"], member["path"]), recursive=False)
                tf.add(manifest_path, arcname="manifest.json", recursive=False)
            os.replace(temporary, out)
            os.chmod(out, 0o600)
        finally:
            temporary.unlink(missing_ok=True)
    return validate_archive(out)


def _load_archive(archive: Path, extract_to: Path | None = None) -> dict:
    if not archive.is_file() or archive.stat().st_size == 0:
        raise RuntimeError(f"archive missing or empty: {archive}")
    with tarfile.open(archive, "r:gz") as tf:
        all_members = tf.getmembers()
        by_name = {member.name: member for member in all_members}
        manifest_member = by_name.get("manifest.json")
        if not manifest_member or not manifest_member.isfile():
            raise RuntimeError("manifest.json missing from continuity archive")
        try:
            manifest = json.loads(tf.extractfile(manifest_member).read().decode("utf-8"))
        except Exception as exc:  # noqa: BLE001
            raise RuntimeError(f"cannot parse continuity manifest: {exc}") from exc
        if manifest.get("schema") not in SUPPORTED_SCHEMAS or not isinstance(manifest.get("members"), list):
            raise RuntimeError("unsupported or malformed continuity manifest")
        wanted = {"manifest.json"}
        locations: list[tuple[dict, str, str, str]] = []
        seen: set[tuple[str, str]] = set()
        for row in manifest["members"]:
            if not isinstance(row, dict):
                raise RuntimeError("malformed continuity member")
            scope, path, name = _row_location(manifest, row)
            if (scope, path) in seen:
                raise RuntimeError("duplicate continuity member")
            seen.add((scope, path))
            wanted.add(name)
            member = by_name.get(name)
            if not member or not member.isfile() or member.issym() or member.islnk():
                raise RuntimeError(f"missing or unsafe member: {name}")
            locations.append((row, scope, path, name))
        names = {member.name for member in all_members}
        if names != wanted:
            raise RuntimeError("archive has unexpected or missing members")
        if extract_to is not None:
            for row, scope, path, name in locations:
                out = extract_to / "payload" / scope / path
                out.parent.mkdir(parents=True, exist_ok=True)
                src = tf.extractfile(name)
                if src is None:
                    raise RuntimeError(f"cannot read {path}")
                with out.open("wb") as dst:
                    shutil.copyfileobj(src, dst)
                expected = row.get("sha256")
                if not isinstance(expected, str) or sha256(out) != expected:
                    raise RuntimeError(f"digest mismatch: {scope}/{path}")
                if row.get("kind") == "sqlite":
                    actual = db_stats(out)
                    claimed = row.get("sqlite") or {}
                    for key in ("integrity", "sessions", "messages", "sessions_by_source"):
                        if key in claimed and actual.get(key) != claimed.get(key):
                            raise RuntimeError(f"SQLite stats mismatch for {scope}/{path}: {key}")
    return manifest


def validate_archive(archive: Path) -> dict:
    with tempfile.TemporaryDirectory(prefix="hermes-continuity-verify-") as td:
        manifest = _load_archive(archive, Path(td))
    databases = [row for row in manifest["members"] if row.get("kind") == "sqlite"]
    return {
        "created_at": manifest.get("created_at"),
        "handoff": bool(manifest.get("handoff")),
        "members": len(manifest["members"]),
        "databases": len(databases),
        "message_count": sum(int((row.get("sqlite") or {}).get("messages", 0)) for row in databases),
        "sha256": sha256(archive),
        "bytes": archive.stat().st_size,
        "schema": manifest.get("schema"),
    }


def _destination(scope: str, path: str, home: Path, root_home: Path) -> Path:
    if scope == "hermes":
        return home / path
    if scope == "root" and _valid_root_path(path):
        return root_home / path
    raise RuntimeError("invalid continuity destination")


def _exists(path: Path) -> bool:
    return path.exists() or path.is_symlink()


def _transactional_install(replacements: list[tuple[Path, Path]], removals: list[Path]) -> None:
    """Install a fully verified staged set, rolling back every file on error."""
    token = f"continuity-{os.getpid()}-{os.urandom(5).hex()}"
    operations: list[dict] = []
    destinations: set[Path] = set()
    for destination, source in replacements:
        if destination in destinations:
            raise RuntimeError(f"duplicate restore destination: {destination}")
        destinations.add(destination)
        if destination.is_dir():
            raise RuntimeError(f"restore destination is a directory: {destination}")
        destination.parent.mkdir(parents=True, exist_ok=True)
        replacement = destination.with_name(f".{destination.name}.{token}.new")
        if _exists(replacement):
            raise RuntimeError(f"temporary restore path unexpectedly exists: {replacement}")
        shutil.copy2(source, replacement)
        if sha256(source) != sha256(replacement):
            replacement.unlink(missing_ok=True)
            raise RuntimeError(f"failed to stage restore replacement: {destination}")
        operations.append({"dest": destination, "new": replacement, "old": None, "had": False})
    for destination in removals:
        if destination in destinations:
            continue
        destinations.add(destination)
        if destination.is_dir():
            raise RuntimeError(f"restore deletion target is a directory: {destination}")
        operations.append({"dest": destination, "new": None, "old": None, "had": False})

    journal: list[dict] = []
    try:
        for index, op in enumerate(operations):
            destination = op["dest"]
            backup = destination.with_name(f".{destination.name}.{token}.{index}.old")
            if _exists(backup):
                raise RuntimeError(f"temporary restore backup unexpectedly exists: {backup}")
            if _exists(destination):
                os.replace(destination, backup)
                op["had"] = True
                op["old"] = backup
            journal.append(op)
            if op["new"] is not None:
                os.replace(op["new"], destination)
        # Commit: old copies are no longer needed only after every destination
        # has been switched successfully. A cleanup issue leaves an inert hidden
        # rollback copy, not a failed/partly-reversed restore transaction.
        for op in journal:
            if op["old"] is not None:
                try:
                    op["old"].unlink(missing_ok=True)
                except OSError:
                    pass
    except Exception:
        # A failed restore must leave the previous live state intact. This is
        # deliberately independent of archive validation, which happened first.
        for op in reversed(journal):
            destination = op["dest"]
            if _exists(destination):
                destination.unlink(missing_ok=True)
            if op["had"] and op["old"] is not None and _exists(op["old"]):
                os.replace(op["old"], destination)
        raise
    finally:
        for op in operations:
            if op["new"] is not None:
                op["new"].unlink(missing_ok=True)
            if op["old"] is not None:
                op["old"].unlink(missing_ok=True)


def restore_archive(home: Path, root_home: Path, archive: Path, marker: Path | None = None) -> dict:
    home = home.resolve()
    root_home = root_home.resolve()
    with tempfile.TemporaryDirectory(prefix="hermes-continuity-restore-") as td:
        staged = Path(td)
        manifest = _load_archive(archive, staged)
        expected: set[tuple[str, str]] = set()
        replacements: list[tuple[Path, Path]] = []
        sqlite_destinations: list[Path] = []
        for row in manifest["members"]:
            scope, path, _ = _row_location(manifest, row)
            expected.add((scope, path))
            source = staged / "payload" / scope / path
            destination = _destination(scope, path, home, root_home)
            replacements.append((destination, source))
            if row.get("kind") == "sqlite":
                sqlite_destinations.append(destination)

        # Schema 1 was intentionally only a narrow conversation archive; never
        # use it to prune data it could not possibly know about. Schema 2 is an
        # exact snapshot of its policy-covered state, so deletions carry over.
        removals: list[Path] = []
        if manifest.get("schema") >= 2:
            for item in discover(home, root_home, require_state_db=False):
                if (item.scope, item.path) not in expected:
                    removals.append(_destination(item.scope, item.path, home, root_home))
        # A SQLite backup folds WAL into the copied DB. Remove stale auxiliary
        # files in the same transaction, after keeping rollback copies of them.
        for destination in sqlite_destinations:
            for suffix in ("-wal", "-shm"):
                auxiliary = Path(str(destination) + suffix)
                if _exists(auxiliary):
                    removals.append(auxiliary)
        _transactional_install(replacements, removals)

    result = validate_archive(archive)
    result.update({"restored_at": utc_now(), "home": str(home), "root_home": str(root_home)})
    if marker:
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        os.chmod(marker, 0o600)
    return result


def selftest() -> None:
    """Offline test only: no network, Telegram, Instagram or live state."""
    with tempfile.TemporaryDirectory(prefix="hermes-continuity-selftest-") as td:
        base = Path(td)
        source = base / "source"
        root = base / "root"
        (source / "memories").mkdir(parents=True)
        (source / "memories" / "MEMORY.md").write_text("test memory\n", encoding="utf-8")
        (source / "memories" / "USER.md").write_text("test user\n", encoding="utf-8")
        (source / "sessions").mkdir()
        (source / "sessions" / "sessions.json").write_text("{}\n", encoding="utf-8")
        (source / "skills" / "custom-bot").mkdir(parents=True)
        (source / "skills" / "custom-bot" / "SKILL.md").write_text("durable skill\n", encoding="utf-8")
        (source / "profiles" / "instagram-bot").mkdir(parents=True)
        (source / "profiles" / "instagram-bot" / ".env").write_text("profile secret stays private\n", encoding="utf-8")
        (source / "SOUL.md").write_text("durable Bot Mode identity\n", encoding="utf-8")
        (source / "config.yaml").write_text("memory:\n  memory_enabled: true\n", encoding="utf-8")
        (source / ".env").write_text("vault-only top-level secret\n", encoding="utf-8")
        (source / "cache").mkdir()
        (source / "cache" / "discard.txt").write_text("ephemeral\n", encoding="utf-8")
        database = source / "state.db"
        con = sqlite3.connect(database)
        con.execute("create table sessions (id text, source text)")
        con.execute("create table messages (id integer, body text)")
        con.execute("insert into sessions values ('s1', 'telegram')")
        con.execute("insert into messages values (1, 'not exposed in logs')")
        con.commit()
        con.close()
        (root / ".composio").mkdir(parents=True)
        (root / ".composio" / "credentials.json").write_text("private integration state\n", encoding="utf-8")
        (root / ".composio" / "composio").write_text("rebuildable binary\n", encoding="utf-8")
        archive = base / "continuity.tar.gz"
        info = make_archive(source, root, archive, handoff=True)
        assert info["message_count"] == 1 and info["handoff"] and info["schema"] == SCHEMA

        target = base / "target"
        target_root = base / "target-root"
        (target / "skills" / "deleted-skill").mkdir(parents=True)
        (target / "skills" / "deleted-skill" / "SKILL.md").write_text("stale\n", encoding="utf-8")
        (target_root / ".composio").mkdir(parents=True)
        (target_root / ".composio" / "stale.json").write_text("stale\n", encoding="utf-8")
        result = restore_archive(target, target_root, archive, base / "marker.json")
        con = sqlite3.connect(target / "state.db")
        assert con.execute("select count(*) from messages").fetchone()[0] == 1
        con.close()
        assert (target / "skills" / "custom-bot" / "SKILL.md").read_text(encoding="utf-8") == "durable skill\n"
        assert (target / "profiles" / "instagram-bot" / ".env").is_file()
        assert not (target / ".env").exists()
        assert not (target / "cache" / "discard.txt").exists()
        assert not (target / "skills" / "deleted-skill" / "SKILL.md").exists()
        assert (target_root / ".composio" / "credentials.json").is_file()
        assert not (target_root / ".composio" / "composio").exists()
        assert not (target_root / ".composio" / "stale.json").exists()
        assert result["databases"] == 1
    print("hermes continuity selftest: PASS")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    p_ck = sub.add_parser("checkpoint")
    p_ck.add_argument("--home", default="/root/.hermes")
    p_ck.add_argument("--root-home", default="/root")
    p_ck.add_argument("--out", required=True)
    p_ck.add_argument("--handoff", action="store_true")
    p_val = sub.add_parser("validate")
    p_val.add_argument("--archive", required=True)
    p_re = sub.add_parser("restore")
    p_re.add_argument("--home", default="/root/.hermes")
    p_re.add_argument("--root-home", default="/root")
    p_re.add_argument("--archive", required=True)
    p_re.add_argument("--marker", default="/var/lib/hermes-continuity/last-restore.json")
    p_fp = sub.add_parser("fingerprint")
    p_fp.add_argument("--home", default="/root/.hermes")
    p_fp.add_argument("--root-home", default="/root")
    sub.add_parser("selftest")
    args = parser.parse_args()
    try:
        if args.command == "checkpoint":
            result = make_archive(Path(args.home), Path(args.root_home), Path(args.out), args.handoff)
        elif args.command == "validate":
            result = validate_archive(Path(args.archive))
        elif args.command == "restore":
            result = restore_archive(Path(args.home), Path(args.root_home), Path(args.archive), Path(args.marker))
        elif args.command == "fingerprint":
            print(live_fingerprint(Path(args.home), Path(args.root_home)))
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
