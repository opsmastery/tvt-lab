#!/usr/bin/env bash
# Adds or removes a reader of one metric (tvt S9 item 4): a provisioned
# dashboard with one panel on it, so evidence that an owner confirmed can
# change under them. Grafana's file provider picks the change up within
# its poll interval; the next tvt scan sees the new reader.
#
#   scripts/s9-reader.sh add METRIC
#   scripts/s9-reader.sh remove
set -euo pipefail
cd "$(dirname "$0")/.."
f=grafana/dashboards/s9-reader.json
case "${1:-}" in
add)
  m="${2:?metric name}"
  [[ "$m" =~ ^[a-zA-Z_:][a-zA-Z0-9_:]*$ ]] || { echo "not a metric name: $m" >&2; exit 2; }
  cat > "$f" <<JSON
{
  "uid": "s9-reader",
  "title": "S9 reader",
  "description": "A reader added by scripts/s9-reader.sh to reopen an owner's confirmation (tvt S9).",
  "schemaVersion": 41,
  "version": 1,
  "editable": true,
  "tags": ["tvt-lab", "s9"],
  "time": {"from": "now-6h", "to": "now"},
  "panels": [
    {
      "id": 1,
      "type": "timeseries",
      "title": "$m",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"x": 0, "y": 0, "w": 12, "h": 8},
      "targets": [{"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "sum(rate($m[5m]))"}]
    }
  ]
}
JSON
  echo "added a reader of $m ($f)";;
remove)
  rm -f "$f"; echo "removed $f";;
*)
  echo "usage: $0 add METRIC | remove" >&2; exit 2;;
esac
