#!/usr/bin/env bash
# Export the lab's data volumes so the lab can move to another machine with
# its history (tvt needs 30+ days of it). Run on the machine the lab runs on:
#
#   scripts/export-volumes.sh /Volumes/Storage/tvt-lab-volumes
#
# It stops the lab's containers (not the kube-prometheus-stack kind cluster),
# writes one tar per volume plus SHA256SUMS and MANIFEST into DEST, and leaves
# the lab stopped: data written after the export would be lost on the new
# machine anyway. Restart here with `make up-mimir` if you change your mind.
# Import on the new machine with scripts/import-volumes.sh.
set -euo pipefail

DEST=${1:?usage: $0 DEST_DIR}
PROJECT=tvt-lab
# shop-logs is left out: it only holds the debug log Fluent Bit is tailing.
VOLUMES=(prometheus-data loki-data mimir-data grafana-data alloy-data fluent-bit-data)

mkdir -p "$DEST"
if compgen -G "$DEST/*.tar" >/dev/null; then
  echo "export: $DEST already has .tar files; use an empty directory" >&2
  exit 1
fi

for v in "${VOLUMES[@]}"; do
  podman volume exists "${PROJECT}_$v" || { echo "export: no volume ${PROJECT}_$v" >&2; exit 1; }
done

running=$(podman ps -q --filter "label=com.docker.compose.project=$PROJECT")
if [ -n "$running" ]; then
  echo "export: stopping the lab's containers (kind cluster untouched)"
  # Stop writers first so the TSDB, Loki and Mimir close their WAL cleanly.
  podman stop --time 60 $running >/dev/null
fi

{
  echo "exported_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "from_host: $(hostname -s)"
  echo "podman: $(podman version --format '{{.Client.Version}}')"
  echo "repo_commit: $(git -C "$(dirname "$0")/.." rev-parse --short HEAD)"
  echo "volumes:"
} > "$DEST/MANIFEST"

for v in "${VOLUMES[@]}"; do
  out="$DEST/$v.tar"
  echo "export: $v -> $out"
  start=$(date +%s)
  podman volume export "${PROJECT}_$v" --output "$out.partial"
  mv "$out.partial" "$out"
  bytes=$(stat -f %z "$out" 2>/dev/null || stat -c %s "$out")
  echo "  - {name: $v, bytes: $bytes, seconds: $(( $(date +%s) - start ))}" >> "$DEST/MANIFEST"
done

echo "export: checksums"
( cd "$DEST" && shasum -a 256 ./*.tar > SHA256SUMS )

cat <<EOF
export: done. The lab here is stopped.
On the new machine, from its tvt-lab checkout:
  scripts/import-volumes.sh "$DEST"     # or wherever that directory is mounted there
  make up-mimir
EOF
