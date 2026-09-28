#!/usr/bin/env python3
"""
state_sync.py — Robust, atomic download & upload of persistent server state
to/from a dedicated GitHub Release in PERSIST_REPO (rolling single snapshot).

v4 design (fixes the "asset name collision" 422 and avoids duplicate backups):
  * upload()  -> ALWAYS uses a UNIQUE asset name   state-<UTC>-<sha8>.tar.gz
                 so GitHub never rejects it with 422 "already_exists".
                 If an asset with the SAME content digest already exists on the
                 release, the upload is SKIPPED entirely (nothing changes).
                 Older assets are deleted ONLY AFTER the new asset is confirmed
                 uploaded => at rest there is exactly ONE state snapshot and a
                 crash between steps never leaves the store empty.
  * download()-> picks the NEWEST state asset (never a hard-coded name).

Usage:
  state_sync.py download <dest_file>
  state_sync.py upload   <src_file>
Env: PERSIST_TOKEN, PERSIST_REPO, STATE_TAG
"""
import sys
import os
import time
import hashlib
import datetime
import urllib.request
import urllib.error
import json

API = "https://api.github.com"
UPLOADS = "https://uploads.github.com"
# A small continuity checkpoint may override these through the environment; the
# broad DR archive keeps the established defaults. Values are bounded so a bad
# environment cannot leave a runner waiting indefinitely.
def _env_int(name, default, low, high):
    try:
        value = int(os.environ.get(name, default))
    except (TypeError, ValueError):
        value = default
    return max(low, min(high, value))

RETRIES = _env_int("PERSIST_RETRIES", 4, 1, 6)
CONNECT_TIMEOUT = _env_int("PERSIST_CONNECT_TIMEOUT", 15, 3, 60)
READ_TIMEOUT = _env_int("PERSIST_READ_TIMEOUT", 120, 10, 300)
USER_AGENT = "Linux-server-persist-agent-v4"


def now_utc():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def sha256_file(path, chunk=1024 * 1024):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(chunk)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def _headers(token, accept="application/vnd.github+json"):
    return {
        "Authorization": f"Bearer {token}",
        "Accept": accept,
        "User-Agent": USER_AGENT,
        "X-GitHub-Api-Version": "2022-11-28",
    }


def _request(method, url, token, body=None, headers=None, accept=None):
    """Perform an HTTP request with retries/backoff. Returns parsed JSON."""
    hdrs = _headers(token, accept or "application/vnd.github+json")
    if headers:
        hdrs.update(headers)
    data = body.encode() if isinstance(body, str) else body
    last = None
    for attempt in range(1, RETRIES + 1):
        req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
        try:
            with urllib.request.urlopen(req, timeout=READ_TIMEOUT) as resp:
                raw = resp.read()
                if not raw:
                    return {}
                return json.loads(raw.decode())
        except urllib.error.HTTPError as e:
            # v4.1: 401 is retried too — on 2026-09-10 the API returned
            # transient 401s for ~15 min on a VALID token and three
            # consecutive save failures aborted a healthy server. A truly
            # bad token still fails after all retries (no behavior change).
            if e.code in (401, 403, 429, 500, 502, 503, 504):
                last = e
                print(f"[persist] transient HTTP {e.code} (attempt {attempt}/{RETRIES}), retrying...",
                      file=sys.stderr)
                time.sleep(2 * attempt)
                continue
            if e.code == 404:
                # capture body for better diagnostics (e.g., release missing)
                try:
                    msg = json.loads(e.read().decode()).get("message", "")
                except Exception:
                    msg = ""
                raise RuntimeError(f"HTTP {e.code} {msg}") from e
            raise RuntimeError(f"HTTP {e.code}") from e
        except urllib.error.URLError as e:
            last = e
            print(f"[persist] network error (attempt {attempt}/{RETRIES}): {e}", file=sys.stderr)
            time.sleep(2 * attempt)
        except Exception as e:  # socket timeouts etc.
            last = e
            print(f"[persist] error (attempt {attempt}/{RETRIES}): {e}", file=sys.stderr)
            time.sleep(2 * attempt)
    raise RuntimeError(f"request failed after {RETRIES} attempts: {last}")


def get_release(repo, tag, token):
    url = f"{API}/repos/{repo}/releases/tags/{tag}"
    try:
        return _request("GET", url, token)
    except RuntimeError as e:
        if "404" in str(e):
            return None
        raise


def ensure_release(repo, tag, token):
    rel = get_release(repo, tag, token)
    if rel:
        return rel
    print(f"[persist] creating rolling release '{tag}' in {repo}...")
    body = json.dumps({
        "tag_name": tag,
        "name": "Persistent state (rolling)",
        "body": "Rolling single-snapshot state for Linux-server — auto-updated by workflow.",
        "draft": False,
        "prerelease": False,
    })
    url = f"{API}/repos/{repo}/releases"
    return _request("POST", url, token, body=body)


def _asset_is_state(a, kind="state"):
    """Return True only for archives belonging to one logical persistence stream."""
    name = a.get("name", "")
    # state.tar.gz is the legacy name used by early broad backups. It must not
    # be selected by the Hermes continuity stream.
    if kind == "state" and name == "state.tar.gz":
        return True
    return name.startswith(kind + "-") and name.endswith(".tar.gz")


def _kind(value):
    value = (value or "state").strip().lower()
    if not value or any(c not in "abcdefghijklmnopqrstuvwxyz0123456789-" for c in value):
        raise RuntimeError(f"invalid persistence kind: {value!r}")
    return value


def delete_asset(repo, asset_id, token):
    url = f"{API}/repos/{repo}/releases/assets/{asset_id}"
    try:
        _request("DELETE", url, token)
        return True
    except Exception as e:
        print(f"[persist] warn: could not delete old asset {asset_id}: {e}", file=sys.stderr)
        return False


def verify_asset(repo, asset_id, token, digest, size):
    """Confirm the just-uploaded asset is actually persisted and byte-identical
    to what we uploaded, BEFORE the previous healthy asset is purged."""
    url = f"{API}/repos/{repo}/releases/assets/{asset_id}"
    try:
        a = _request("GET", url, token)
    except Exception as e:
        print(f"[persist] verify: asset {asset_id} not readable: {e}", file=sys.stderr)
        return False
    expected_digest = f"sha256:{digest}"
    got_digest = a.get("digest") or ""
    if got_digest == expected_digest and a.get("size") == size:
        return True
    # digest field may be absent on some API versions -> re-download and hash
    print("[persist] verify: digest field absent/different — re-downloading to verify", file=sys.stderr)
    tmp = f"/tmp/state-verify-{asset_id}.tmp"
    try:
        req = urllib.request.Request(
            a["url"], headers=_headers(token, accept="application/octet-stream"))
        with urllib.request.urlopen(req, timeout=READ_TIMEOUT) as resp, \
                open(tmp, "wb") as f:
            while chunk := resp.read(1024 * 1024):
                f.write(chunk)
        ok = (os.path.getsize(tmp) == size and sha256_file(tmp) == digest)
        os.remove(tmp)
        return ok
    except Exception as e:
        print(f"[persist] verify: download failed: {e}", file=sys.stderr)
        return False


def download(repo, tag, dest_file, token, kind="state"):
    print(f"[persist] checking state release '{tag}' in {repo} ...")
    rel = get_release(repo, tag, token)
    if not rel:
        print(f"[persist] no release '{tag}' found (fresh state expected)")
        return False
    assets = [a for a in rel.get("assets", []) if _asset_is_state(a, kind)]
    if not assets:
        print(f"[persist] no state asset on release '{tag}' (fresh state expected)")
        return False
    # Newest first by created_at. A continuity restore may request a previous
    # verified asset when its newest local validation rejects an archive.
    assets.sort(key=lambda a: a.get("created_at", ""), reverse=True)
    offset = _env_int("PERSIST_DOWNLOAD_OFFSET", 0, 0, 8)
    if offset >= len(assets):
        print(f"[persist] no {kind} asset at rollback offset {offset}", file=sys.stderr)
        return False
    target = assets[offset]
    print(f"[persist] selected {kind} asset offset={offset}: {target['name']} "
          f"({target.get('size', 0)} bytes, created {target.get('created_at')})")
    url = target["url"]
    try:
        req = urllib.request.Request(
            url, headers=_headers(token, accept="application/octet-stream"))
        with urllib.request.urlopen(req, timeout=READ_TIMEOUT) as resp, \
                open(dest_file, "wb") as f:
            while chunk := resp.read(1024 * 1024):
                f.write(chunk)
    except Exception as e:
        print(f"[persist] download failed: {e}", file=sys.stderr)
        return False
    size = os.path.getsize(dest_file)
    if size == 0:
        print("[persist] downloaded file is empty -> treat as no state", file=sys.stderr)
        os.remove(dest_file)
        return False
    print(f"[persist] download complete -> {dest_file} ({size} bytes)")
    return True


def upload(repo, tag, src_file, token, kind="state"):
    if not os.path.isfile(src_file):
        print(f"[persist] source file not found: {src_file}", file=sys.stderr)
        return False
    digest = sha256_file(src_file)
    size = os.path.getsize(src_file)
    print(f"[persist] snapshot digest sha256:{digest[:16]}... size={size}")

    rel = ensure_release(repo, tag, token)
    assets = rel.get("assets", [])

    # 1) Skip upload if identical content already persisted (no new backup).
    existing = [a for a in assets if _asset_is_state(a, kind)]
    for a in existing:
        if digest.startswith(a.get("name", "")[-24:].replace(".tar.gz", "")) or \
                digest[:8] in a.get("name", ""):
            print(f"[persist] state unchanged (asset '{a['name']}' already matches) -> skip upload")
            return True

    # 2) Upload under a unique name (never collides with previous assets).
    name = f"{kind}-{now_utc()}-{digest[:8]}.tar.gz"
    upload_url = rel["upload_url"].split("{")[0]
    url = f"{upload_url}?name={name}"
    print(f"[persist] uploading {name} ({size} bytes) ...")
    with open(src_file, "rb") as f:
        data = f.read()
    headers = {"Content-Type": "application/gzip"}
    try:
        result = _request("POST", url, token, body=data, headers=headers)
    except Exception as e:
        print(f"[persist] upload error: {e}", file=sys.stderr)
        return False
    new_id = result.get("id")
    print(f"[persist] upload OK -> asset id={new_id} name={result.get('name')} "
          f"size={result.get('size')} digest={result.get('digest', '')[:32]}")

    # 2b) Verify the persisted copy BEFORE touching the previous healthy asset,
    #     so a corrupt/half-upload never replaces the last good state.
    if not new_id or not verify_asset(repo, new_id, token, digest, size):
        print("[persist] VERIFY FAILED — new asset not confirmed; previous "
              "healthy state is retained", file=sys.stderr)
        if new_id:
            delete_asset(repo, new_id, token)  # best effort cleanup
        return False

    # 3) Purge only this stream's old assets. Keep the confirmed new copy plus
    #    a configurable number of previous verified archives for rollback.
    try:
        keep_previous = max(1, min(8, int(os.environ.get("PERSIST_KEEP_PREVIOUS", "1"))))
    except ValueError:
        keep_previous = 1
    keep_ids = {new_id}
    older = [a for a in assets
             if a.get("id") != new_id and _asset_is_state(a, kind) and a.get("id")]
    older.sort(key=lambda a: a.get("created_at", ""), reverse=True)
    for prior in older[:keep_previous]:
        keep_ids.add(prior.get("id"))
        print(f"[persist] keeping rollback asset '{prior['name']}'")
    for a in assets:
        if a.get("id") in keep_ids or not _asset_is_state(a, kind):
            continue
        # never delete an asset whose digest matches ours (already covered by skip)
        print(f"[persist] purging stale asset '{a['name']}' (id {a['id']})")
        delete_asset(repo, a["id"], token)
    return True


def main():
    if len(sys.argv) < 3:
        print("Usage: state_sync.py <download|upload> <file_path> [--kind state|hermes]", file=sys.stderr)
        sys.exit(2)
    action, file_path = sys.argv[1], sys.argv[2]
    if action not in ("download", "upload"):
        print(f"[persist] ERROR: unknown action {action!r}", file=sys.stderr)
        sys.exit(2)
    raw_kind = os.environ.get("PERSIST_KIND", "state")
    rest = sys.argv[3:]
    if rest:
        if len(rest) != 2 or rest[0] != "--kind":
            print("Usage: state_sync.py <download|upload> <file_path> [--kind state|hermes]", file=sys.stderr)
            sys.exit(2)
        raw_kind = rest[1]
    try:
        kind = _kind(raw_kind)
    except RuntimeError as exc:
        print(f"[persist] ERROR: {exc}", file=sys.stderr)
        sys.exit(2)
    token = os.environ.get("PERSIST_TOKEN") or os.environ.get("GH_TOKEN") or \
        os.environ.get("GITHUB_TOKEN")
    repo = os.environ.get("PERSIST_REPO") or "hrgh3d/Linux-server-state"
    tag = os.environ.get("STATE_TAG") or "state"
    if not token:
        print("[persist] ERROR: no token (set PERSIST_TOKEN/GH_TOKEN)", file=sys.stderr)
        sys.exit(1)
    operation = download if action == "download" else upload
    ok = operation(repo, tag, file_path, token, kind)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
