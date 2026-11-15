#!/bin/sh
# Check that the running lab loaded what's on disk: every rule and Grafana
# alert in this repo must be live, or ground-truth.yaml describes a lab
# that doesn't exist. Grafana reads alert provisioning only at start, and
# Prometheus and Loki read rule files at start or on reload, so a file
# added while the stack runs stays unloaded until a restart.
#
#   make check-live
#   GRAFANA_TOKEN=... make check-live    # a service-account token instead
#                                        # of GRAFANA_AUTH (admin:admin)
#
# Read-only: GETs against the local lab. Needs curl and jq.
set -eu

PROM=${PROM:-http://localhost:9090}
LOKI=${LOKI:-http://localhost:3100}
GRAFANA=${GRAFANA:-http://localhost:3000}
GRAFANA_AUTH=${GRAFANA_AUTH:-admin:admin}
ALLOY=${ALLOY:-http://localhost:12345}

fail=0
# compare <what> <want file> <got file> <fix>
compare() {
  missing=$(comm -23 "$2" "$3")
  if [ -n "$missing" ]; then
    echo "FAIL $1 not loaded:" >&2
    echo "$missing" | sed 's/^/       /' >&2
    echo "     fix: $4" >&2
    fail=1
  else
    echo "  ok  $1 ($(wc -l < "$2" | tr -d ' ') loaded)"
  fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Rule names in the repo's rule files.
names() { grep -hE '^[[:space:]]*- (alert|record):' "$@" | sed -E 's/.*- (alert|record):[[:space:]]*//; s/^"//; s/"$//' | sort -u; }

names prometheus/rules/*.yml > "$tmp/prom.want"
curl -fsS "$PROM/api/v1/rules" | jq -r '.data.groups[].rules[].name' | sort -u > "$tmp/prom.got"
compare "Prometheus rules" "$tmp/prom.want" "$tmp/prom.got" "curl -X POST $PROM/-/reload, or podman compose restart prometheus"

names loki/rules/*/*.yml > "$tmp/loki.want"
curl -fsS "$LOKI/loki/api/v1/rules" | sed -nE 's/^[[:space:]]*- (alert|record):[[:space:]]*//p' | sort -u > "$tmp/loki.got"
compare "Loki rules" "$tmp/loki.want" "$tmp/loki.got" "podman compose restart loki"

grep -hE '^[[:space:]]*- uid:' grafana/provisioning/alerting/*.yml | sed -E 's/.*uid:[[:space:]]*//' | sort -u > "$tmp/grafana.want"
if [ -n "${GRAFANA_TOKEN:-}" ]; then
  set -- -H "Authorization: Bearer $GRAFANA_TOKEN"
else
  set -- -u "$GRAFANA_AUTH"
fi
curl -fsS "$@" "$GRAFANA/api/ruler/grafana/api/v1/rules" | jq -r '.[][].rules[].grafana_alert.uid' | sort -u > "$tmp/grafana.got"
compare "Grafana-managed alerts" "$tmp/grafana.want" "$tmp/grafana.got" "podman compose restart grafana (alert provisioning is read only at start)"

# Alloy (the lab's pipeline): every component in alloy/config.alloy is
# running and healthy.
grep -hE '^[a-z_.]+ "[a-z_]+" \{' alloy/config.alloy | sed -E 's/^([a-z_.]+) "([a-z_]+)".*/\1.\2/' | sort -u > "$tmp/alloy.want"
curl -fsS "$ALLOY/api/v0/web/components" | jq -r '.[] | select(.health.state == "healthy") | .localID' | sort -u > "$tmp/alloy.got"
compare "Alloy components (healthy)" "$tmp/alloy.want" "$tmp/alloy.got" "make up (or podman compose restart alloy); see podman compose logs alloy"

exit $fail
