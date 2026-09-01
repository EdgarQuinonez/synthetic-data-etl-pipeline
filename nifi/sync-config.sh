#!/usr/bin/env bash
# Sync the standalone NiFi install (/opt/nifi) into nifi/data so it can be
# mounted into the Docker container. Config, flow, and repositories contain
# secrets (keystore, sensitive props key, encrypted DB password) so data/ is
# gitignored and never committed.
#
# Usage:
#   nifi/sync-config.sh            # copy only if data/conf is empty/missing
#   nifi/sync-config.sh --force    # re-copy and overwrite everything
set -uo pipefail

SRC="${NIFI_HOST_HOME:-/opt/nifi}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DST="$REPO_DIR/nifi/data"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

DIRS="conf content_repository database_repository flowfile_repository provenance_repository state logs"

if [ ! -d "$SRC" ]; then
  echo "error: source NiFi home '$SRC' not found" >&2
  exit 1
fi
if [ ! -f "$SRC/conf/nifi.properties" ]; then
  echo "error: '$SRC/conf/nifi.properties' not found; is this really a NiFi home?" >&2
  exit 1
fi

for d in $DIRS; do
  [ -d "$SRC/$d" ] || continue
  if [ -d "$DST/$d" ] && [ "$FORCE" = "0" ] && [ "$d" = "conf" ] && [ -f "$DST/$d/nifi.properties" ]; then
    echo "skip $d (already synced; use --force to refresh)"
    continue
  fi
  if [ -d "$DST/$d" ] && [ "$FORCE" = "0" ] && [ "$d" != "conf" ] && [ -n "$(ls -A "$DST/$d" 2>/dev/null)" ]; then
    echo "skip $d (already synced; use --force to refresh)"
    continue
  fi
  mkdir -p "$DST/$d"
  cp -a "$SRC/$d"/. "$DST/$d/"
  echo "synced $d"
done

echo "done. config synced to $DST"