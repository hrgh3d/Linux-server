#!/usr/bin/env python3
"""
state_sync.py — Handles robust, atomic download & upload of persistent state
to/from the dedicated GitHub Release in PERSIST_REPO.
Ensures exactly ONE rolling state.tar.gz asset exists without duplicates.
"""
import sys
import os
import urllib.request
import urllib.error
import json

def get_headers(token, accept="application/vnd.github+json"):
    return {
        "Authorization": f"Bearer {token}",
        "Accept": accept,
        "User-Agent": "Linux-server-persist-agent"
    }

def get_release(repo, tag, token):
    url = f"https://api.github.com/repos/{repo}/releases/tags/{tag}"
    req = urllib.request.Request(url, headers=get_headers(token))
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        print(f"[persist] HTTP error checking release: {e}", file=sys.stderr)
        raise

def ensure_release(repo, tag, token):
    rel = get_release(repo, tag, token)
    if rel:
        return rel
    print(f"[persist] creating rolling release '{tag}' in {repo}...")
    url = f"https://api.github.com/repos/{repo}/releases"
    payload = json.dumps({
        "tag_name": tag,
        "name": "Persistent state (rolling)",
        "body": "Rolling state archive for Linux-server — automatically updated by workflow.",
        "draft": False,
        "prerelease": False
    }).encode()
    req = urllib.request.Request(url, data=payload, headers=get_headers(token), method="POST")
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read().decode())

def delete_asset(repo, asset_id, token):
    url = f"https://api.github.com/repos/{repo}/releases/assets/{asset_id}"
    req = urllib.request.Request(url, headers=get_headers(token), method="DELETE")
    try:
        with urllib.request.urlopen(req) as resp:
            pass
    except Exception as e:
        print(f"[persist] warn: could not delete asset {asset_id}: {e}", file=sys.stderr)

def download(repo, tag, dest_file, token):
    print(f"[persist] checking release '{tag}' in {repo}...")
    rel = get_release(repo, tag, token)
    if not rel:
        print(f"[persist] no release '{tag}' found in {repo}")
        return False
    
    assets = rel.get("assets", [])
    # Look for state.tar.gz or any .tar.gz asset
    target_asset = next((a for a in assets if a["name"] == "state.tar.gz"), None)
    if not target_asset and assets:
        target_asset = assets[0]
        
    if not target_asset:
        print(f"[persist] no state asset found in release '{tag}'")
        return False
        
    url = target_asset["url"]
    headers = get_headers(token, accept="application/octet-stream")
    req = urllib.request.Request(url, headers=headers)
    print(f"[persist] downloading {target_asset['name']} (size: {target_asset['size']} bytes)...")
    try:
        with urllib.request.urlopen(req) as resp, open(dest_file, "wb") as f:
            while chunk := resp.read(65536):
                f.write(chunk)
        print(f"[persist] download complete -> {dest_file} ({os.path.getsize(dest_file)} bytes)")
        return True
    except Exception as e:
        print(f"[persist] download failed: {e}", file=sys.stderr)
        return False

def upload(repo, tag, src_file, token):
    if not os.path.isfile(src_file):
        print(f"[persist] source file not found: {src_file}", file=sys.stderr)
        return False
        
    file_size = os.path.getsize(src_file)
    print(f"[persist] uploading {src_file} ({file_size} bytes) to {repo} release '{tag}'...")
    
    rel = ensure_release(repo, tag, token)
    upload_url_template = rel["upload_url"]
    upload_url = upload_url_template.split("{")[0] + "?name=state.tar.gz"
    
    # Clean up ALL existing assets on this release tag first to prevent duplicate/stale files
    existing_assets = rel.get("assets", [])
    for a in existing_assets:
        print(f"[persist] removing previous asset '{a['name']}' (id: {a['id']})")
        delete_asset(repo, a["id"], token)
        
    with open(src_file, "rb") as f:
        data = f.read()
        
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/gzip",
        "User-Agent": "Linux-server-persist-agent"
    }
    req = urllib.request.Request(upload_url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req) as resp:
            result = json.loads(resp.read().decode())
            print(f"[persist] upload successful! Asset ID: {result.get('id')}, Size: {result.get('size')} bytes")
            return True
    except Exception as e:
        print(f"[persist] upload error: {e}", file=sys.stderr)
        return False

def main():
    if len(sys.argv) < 3:
        print("Usage: state_sync.py <download|upload> <file_path>", file=sys.stderr)
        sys.exit(1)
        
    action = sys.argv[1]
    file_path = sys.argv[2]
    
    token = os.environ.get("PERSIST_TOKEN") or os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    repo = os.environ.get("PERSIST_REPO") or "hrgh3d/Linux-server-state"
    tag = os.environ.get("STATE_TAG") or "state"
    
    if not token:
        print("[persist] ERROR: No token provided (PERSIST_TOKEN or GH_TOKEN missing)", file=sys.stderr)
        sys.exit(1)
        
    if action == "download":
        success = download(repo, tag, file_path, token)
        sys.exit(0 if success else 1)
    elif action == "upload":
        success = upload(repo, tag, file_path, token)
        sys.exit(0 if success else 1)
    else:
        print(f"[persist] unknown action: {action}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
