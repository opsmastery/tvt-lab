#!/bin/sh
# One-shot loader for the mimir-rules service: wait until Mimir is ready,
# then POST each rule group in /rules to namespace tvt-lab. Re-running it
# replaces the groups, so it is safe on every `make up-mimir`.
set -eu
MIMIR=${MIMIR:-http://mimir:9009}
NAMESPACE=${NAMESPACE:-tvt-lab}

i=0
until curl -fs -o /dev/null "$MIMIR/ready"; do
  i=$((i + 1))
  if [ "$i" -ge 60 ]; then
    echo "mimir-rules: Mimir not ready after 5 minutes" >&2
    exit 1
  fi
  sleep 5
done

for f in /rules/*.yml; do
  curl -fsS -X POST -H 'Content-Type: application/yaml' --data-binary "@$f" \
    -o /dev/null "$MIMIR/prometheus/config/v1/rules/$NAMESPACE"
  echo "mimir-rules: loaded $f into $NAMESPACE"
done
