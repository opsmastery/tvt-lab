#!/bin/sh
# Simulated AI agent clients for tvt-lab (tvt S3 items 5-6). Every
# INTERVAL_SECONDS:
#
#   sweep agent    asks for every metric name at once, the way an MCP
#                  "list what's here" tool does. A sweep is weak evidence:
#                  ground truth expects it to keep nothing on its own.
#   finance agent  asks one question about one metric over 90 days
#                  (shop_revenue_dollars_total, read by nothing else). An
#                  agent naming a metric is a read: keep_medium. In tvt S8 the
#                  90-day range blocks a 30-day retention proposal on it.
#
# Both query Prometheus directly, and Mimir too when it runs (make up-mimir).
# Prometheus's query log records only the client IP; Mimir's query-frontend
# also logs user_agent, which is how tvt can tell the agents apart there.

PROM_URL=${PROM_URL:-http://prometheus:9090}
MIMIR_URL=${MIMIR_URL:-http://mimir:9009/prometheus}
INTERVAL_SECONDS=${INTERVAL_SECONDS:-900}
SWEEP_UA="tvt-lab-sweep-agent/1.0 (mcp)"
FINANCE_UA="tvt-lab-finance-agent/1.0 (mcp)"

ask() { # base user-agent path query [extra curl args...]
  base=$1 ua=$2 path=$3 query=$4
  shift 4
  curl -fsS -o /dev/null -G -A "$ua" "$base$path" --data-urlencode "query=$query" "$@"
}

echo "agent: waiting for Prometheus at $PROM_URL"
until curl -fsS -o /dev/null "$PROM_URL/-/ready"; do sleep 5; done
echo "agent: sweeping and asking every ${INTERVAL_SECONDS}s"

while true; do
  now=$(date +%s)
  for base in "$PROM_URL" "$MIMIR_URL"; do
    # Mimir is optional: a failed request there is expected without the profile.
    quiet=""
    [ "$base" = "$MIMIR_URL" ] && quiet=1
    ask "$base" "$SWEEP_UA" /api/v1/query 'count by (__name__) ({__name__=~".+"})' \
      || [ -n "$quiet" ] || echo "agent: sweep failed on $base"
    ask "$base" "$FINANCE_UA" /api/v1/query_range 'sum by (currency) (rate(shop_revenue_dollars_total[1d]))' \
      --data-urlencode "start=$((now - 90 * 86400))" --data-urlencode "end=$now" --data-urlencode "step=86400" \
      || [ -n "$quiet" ] || echo "agent: finance query failed on $base"
  done
  sleep "$INTERVAL_SECONDS"
done
