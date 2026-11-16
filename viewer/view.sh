#!/bin/sh
# Simulates dashboard usage for tvt-lab.
#
# Every INTERVAL_SECONDS it replays the Shop Overview panel queries through
# Grafana's /api/ds/query endpoint, with the X-Dashboard-Uid and X-Panel-Id
# headers the Grafana frontend sends, and first loads the dashboard JSON the way
# a browser does (GET /api/dashboards/uid/<uid>, with a dashboard Referer).
# Spike 1 found that the dashboard load is the only dashboard-level evidence
# OSS Grafana logs; Prometheus sees panel queries but no attribution.
# About one round in three it also sends an "Explore" query straight to
# Prometheus (ad hoc usage).
#
# The Legacy Queue dashboard is deliberately never queried. Alertmanager
# Health is viewed every round, its panels at a 1m step.

GRAFANA_URL=${GRAFANA_URL:-http://grafana:3000}
GRAFANA_AUTH=${GRAFANA_AUTH:-admin:admin}
PROM_URL=${PROM_URL:-http://prometheus:9090}
LOKI_URL=${LOKI_URL:-http://loki:3100}
INTERVAL_SECONDS=${INTERVAL_SECONDS:-300}
DASH=shop-overview
REFERER="$GRAFANA_URL/d/$DASH/shop-overview?orgId=1"
AM_DASH=alertmanager-health
AM_REFERER="$GRAFANA_URL/d/$AM_DASH/alertmanager-health?orgId=1"

panel_query() { # panel_id datasource_type datasource_uid expr [interval_ms dashboard_uid referer]
  body=$(printf '{"from":"now-1h","to":"now","queries":[{"refId":"A","datasource":{"type":"%s","uid":"%s"},"expr":%s,"intervalMs":%s,"maxDataPoints":500}]}' \
    "$2" "$3" "$4" "${5:-15000}")
  curl -fsS -o /dev/null -u "$GRAFANA_AUTH" \
    -H 'Content-Type: application/json' \
    -H "X-Dashboard-Uid: ${6:-$DASH}" -H "X-Panel-Id: $1" -H 'X-Grafana-Org-Id: 1' \
    -H "Referer: ${7:-$REFERER}" \
    -X POST "$GRAFANA_URL/api/ds/query?ds_type=$2" -d "$body" \
    || echo "viewer: panel $1 query failed"
}

echo "viewer: waiting for Grafana at $GRAFANA_URL"
until curl -fsS -o /dev/null "$GRAFANA_URL/api/health"; do sleep 5; done
echo "viewer: simulating views of $DASH every ${INTERVAL_SECONDS}s"

round=0
while true; do
  round=$((round + 1))
  curl -fsS -o /dev/null -u "$GRAFANA_AUTH" -H "Referer: $REFERER" \
    "$GRAFANA_URL/api/dashboards/uid/$DASH" || echo "viewer: dashboard load failed"
  panel_query 1 prometheus prometheus '"sum by (route) (rate(shop_http_requests_total{route=~\".*\"}[1m]))"'
  panel_query 2 prometheus prometheus '"sum(rate(shop_http_requests_total{status=~\"5..\"}[1m])) / sum(rate(shop_http_requests_total[1m]))"'
  panel_query 3 prometheus prometheus '"route:shop_http_request_duration_seconds:p99_5m{route=~\".*\"}"'
  panel_query 4 prometheus prometheus '"sum by (op) (rate(shop_cart_operations_total[1m]))"'
  panel_query 5 prometheus prometheus '"sum by (mode) (rate(node_cpu_seconds_total[1m]))"'
  panel_query 6 loki loki '"{app=\"shop\", level=~\"info|warn|error\"}"'
  panel_query 7 prometheus prometheus '"sum by (probe) (rate(shop_healthcheck_checks_total{result=\"success\"}[1m])) / sum by (probe) (rate(shop_healthcheck_checks_total[1m]))"'
  panel_query 8 loki loki '"sum by (level) (rate({app=\"shop\", component=\"api\", level=~\"info|warn|error\"}[1m]))"'
  # Panel 9 reads its metric through the $counter variable (tvt S5 distractor);
  # Grafana sends the current value, shop_http_requests_total.
  panel_query 9 prometheus prometheus '"sum(rate(shop_http_requests_total[1m]))"'

  # Alertmanager Health: viewed every round, panels at a 1m step.
  curl -fsS -o /dev/null -u "$GRAFANA_AUTH" -H "Referer: $AM_REFERER" \
    "$GRAFANA_URL/api/dashboards/uid/$AM_DASH" || echo "viewer: alertmanager dashboard load failed"
  panel_query 1 prometheus prometheus '"sum by (state) (alertmanager_alerts)"' 60000 "$AM_DASH" "$AM_REFERER"
  panel_query 2 prometheus prometheus '"sum by (integration) (rate(alertmanager_notifications_total[1m]))"' 60000 "$AM_DASH" "$AM_REFERER"

  if [ $((round % 3)) -eq 0 ]; then
    curl -fsS -o /dev/null -G "$PROM_URL/api/v1/query" \
      --data-urlencode 'query=node_memory_MemAvailable_bytes' \
      || echo "viewer: ad hoc query failed"
    # Support looking up one customer's traffic in the span metrics (tvt S6
    # item 5): customer_id is capped by the cardinality limit, so most
    # customers' points sit in the overflow series and this undercounts.
    curl -fsS -o /dev/null -G "$PROM_URL/api/v1/query" \
      --data-urlencode 'query=sum(rate(traces_span_metrics_calls_total{customer_id="c-0042"}[5m]))' \
      || echo "viewer: customer query failed"
    # On-call digging into failed health checks only: references /healthz
    # lines, but never the successful ones. Failures are logged at warn; the
    # level matcher keeps the query off the debug stream (Loki reads every
    # stream a selector matches, whatever the line filters).
    curl -fsS -o /dev/null -G "$LOKI_URL/loki/api/v1/query_range" \
      --data-urlencode 'query={app="shop", component="api", level=~"warn|error"} |= "route=/healthz" != "status=200"' \
      --data-urlencode 'limit=100' \
      || echo "viewer: ad hoc log query failed"
  fi
  sleep "$INTERVAL_SECONDS"
done
