#!/usr/bin/env bash
# Verified continuity transport for Hermes conversation state.
# The archive deliberately excludes .env/secrets and all runtime/toolchain files.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$SCRIPT_DIR/hermes_continuity.py"
HOME_DIR="${HERMES_HOME:-/root/.hermes}"
ARCHIVE="${HERMES_CONTINUITY_ARCHIVE:-/tmp/hermes-continuity.tar.gz}"
MARKER="${HERMES_CONTINUITY_MARKER:-/var/lib/hermes-continuity/last-restore.json}"
LOCK="${HERMES_CONTINUITY_LOCK:-/run/hermes-continuity.lock}"
FINGERPRINT_FILE="${HERMES_CONTINUITY_FINGERPRINT:-/var/lib/hermes-continuity/live.fingerprint}"

log() { echo "[hermes-continuity $(date -u '+%T')] $*"; }

# A continuity checkpoint is intentionally small; two short API attempts are
# enough for it. The broad DR snapshot keeps its independent retry policy.
export PERSIST_KIND="hermes"
export PERSIST_KEEP_PREVIOUS="${PERSIST_KEEP_PREVIOUS:-3}"
export PERSIST_RETRIES="${PERSIST_RETRIES:-2}"
export PERSIST_READ_TIMEOUT="${PERSIST_READ_TIMEOUT:-30}"

need_token() {
  if [ -z "${PERSIST_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}" ]; then
    log "ERROR: no persistence token available"
    return 1
  fi
}

valid_local_state() {
  python3 - "$HOME_DIR" <<'PY'
import sqlite3, sys
from pathlib import Path
home = Path(sys.argv[1])
dbs = list(home.glob('state.db')) + list(home.glob('profiles/*/state.db'))
if not dbs:
    raise SystemExit(1)
for db in dbs:
    c = sqlite3.connect(f'file:{db}?mode=ro', uri=True, timeout=10)
    try:
        if c.execute('pragma integrity_check').fetchone()[0] != 'ok':
            raise SystemExit(1)
        tables = {r[0] for r in c.execute("select name from sqlite_master where type='table'")}
        if 'sessions' not in tables or 'messages' not in tables:
            raise SystemExit(1)
    finally:
        c.close()
raise SystemExit(0)
PY
}

checkpoint() {
  local handoff="${1:-}"
  need_token
  mkdir -p "$(dirname "$LOCK")" "$(dirname "$ARCHIVE")" "$(dirname "$FINGERPRINT_FILE")"
  exec 9>"$LOCK"
  if [ "$handoff" = "--handoff" ]; then
    # The caller stopped all writers and must not mistake a skipped checkpoint
    # for a final handoff. Wait only briefly for an in-flight periodic copy.
    if ! flock -w 30 9; then
      log "ERROR: final handoff could not acquire continuity lock"
      return 1
    fi
  elif ! flock -n 9; then
    log "checkpoint already running — skip this tick"
    return 0
  fi
  local fingerprint
  fingerprint="$(python3 "$PY" fingerprint --home "$HOME_DIR")"
  if [ "$handoff" != "--handoff" ] && [ -s "$FINGERPRINT_FILE" ] && \
     [ "$(cat "$FINGERPRINT_FILE")" = "$fingerprint" ]; then
    log "state unchanged — checkpoint upload skipped"
    return 0
  fi
  rm -f "$ARCHIVE"
  local args=(checkpoint --home "$HOME_DIR" --out "$ARCHIVE")
  [ "$handoff" = "--handoff" ] && args+=(--handoff)
  python3 "$PY" "${args[@]}"
  # state_sync verifies the uploaded object before it retires any previous copy.
  python3 "$SCRIPT_DIR/state_sync.py" upload "$ARCHIVE" --kind hermes
  printf '%s\n' "$fingerprint" > "$FINGERPRINT_FILE"
  chmod 600 "$FINGERPRINT_FILE"
  log "checkpoint uploaded and verified (handoff=$([ "$handoff" = "--handoff" ] && echo yes || echo no))"
  rm -f "$ARCHIVE"
}

restore() {
  need_token
  # Newest archive first, then up to three retained rollback copies. An asset is
  # not trusted merely because GitHub accepted it: the manifest, hashes and
  # SQLite integrity are checked before any live file is replaced.
  local offset=0
  while [ "$offset" -le 3 ]; do
    rm -f "$ARCHIVE"
    if PERSIST_DOWNLOAD_OFFSET="$offset" python3 "$SCRIPT_DIR/state_sync.py" download "$ARCHIVE" --kind hermes; then
      if python3 "$PY" validate --archive "$ARCHIVE" && \
         python3 "$PY" restore --home "$HOME_DIR" --archive "$ARCHIVE" --marker "$MARKER"; then
        rm -f "$ARCHIVE"
        log "verified continuity state restored (rollback offset=$offset)"
        return 0
      fi
      log "continuity archive at offset=$offset rejected locally; trying older verified copy"
    else
      # There is no point checking later offsets if the selected stream does
      # not exist yet; a genuine transport error also falls through to the
      # fail-closed/fallback check below.
      [ "$offset" -eq 0 ] && break
    fi
    offset=$((offset + 1))
  done
  rm -f "$ARCHIVE"

  # The one-time migration path accepts an already-restored, verified generic
  # state. It never permits a blank/new Hermes database to start by accident.
  if valid_local_state; then
    log "no dedicated checkpoint yet; verified generic restored state accepted for migration"
    return 0
  fi
  log "ERROR: no verified continuity checkpoint and no valid local Hermes state — refusing blank start"
  return 20
}

case "${1:-}" in
  checkpoint) checkpoint "${2:-}" ;;
  restore) restore ;;
  selftest) python3 "$PY" selftest ;;
  *)
    echo "usage: $0 {checkpoint [--handoff]|restore|selftest}" >&2
    exit 2
    ;;
esac
