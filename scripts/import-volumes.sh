#!/usr/bin/env bash
# Import volumes written by scripts/export-volumes.sh on the lab's new
# machine, before its first `make up-mimir`:
#
#   scripts/import-volumes.sh /path/to/tvt-lab-volumes
#
# It checks SHA256SUMS, then creates each volume with the labels
# docker-compose expects (so compose adopts it instead of warning) and
# imports the tar. It refuses to overwrite a volume that already has data
# unless --force is given.
set -euo pipefail

FORCE=0
if [ "${1:-}" = "--force" ]; then FORCE=1; shift; fi
SRC=${1:?usage: $0 [--force] SRC_DIR}
PROJECT=tvt-lab

[ -f "$SRC/SHA256SUMS" ] || { echo "import: no SHA256SUMS in $SRC" >&2; exit 1; }
echo "import: verifying checksums (this reads every tar once)"
( cd "$SRC" && shasum -a 256 -c SHA256SUMS )

if [ -n "$(podman ps -q --filter "label=com.docker.compose.project=$PROJECT")" ]; then
  echo "import: the lab is running here; stop it first (make down)" >&2
  exit 1
fi

for tar in "$SRC"/*.tar; do
  v=$(basename "$tar" .tar)
  name="${PROJECT}_$v"
  if podman volume exists "$name"; then
    used=$(podman run --rm -v "$name:/v:ro" docker.io/library/busybox:1.37 sh -c 'ls -A /v | wc -l')
    if [ "$used" -gt 0 ] && [ "$FORCE" -ne 1 ]; then
      echo "import: $name already has data; rerun with --force to replace it" >&2
      exit 1
    fi
    podman volume rm "$name" >/dev/null
  fi
  echo "import: $v"
  podman volume create \
    --label "com.docker.compose.project=$PROJECT" \
    --label "com.docker.compose.volume=$v" \
    "$name" >/dev/null
  podman volume import "$name" "$tar"
done

echo "import: done. Next: make up-mimir (and make cloud if you use the Grafana Cloud output)."
