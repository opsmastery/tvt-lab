"""Seeded demo app for tvt-lab.

Emits a deliberate mix of telemetry so tvt's findings can be checked against
ground-truth.yaml:

  used:      shop_http_requests_total, shop_http_request_duration_seconds,
             shop_cart_operations_total (but its user_id label is never used)
  alert-only: shop_payment_queue_depth (Prometheus alert),
             shop_order_export_lag_seconds (Grafana-managed alert only)
  stale:     shop_legacy_* (on a dashboard nobody views)
  waste:     shop_cache_* (30 gauges x 16 shards), shop_feature_flag_evaluations_total,
             shop_cache_hits/requests_total (feed only an unused recording rule)

Health checks (the /healthz scenario): a simulated fleet of probers hits
/healthz constantly. Pass rate and latency are tracked in metrics
(shop_healthcheck_*), and every successful check is ALSO logged as an info
line in the same api stream as real traffic. Those success lines are the
largest share of the info stream, and nothing reads them. Failures (503) are
logged at warn and are queried ad hoc.

Logs are pushed to Loki as streams {app="shop", level, component}:
  info/warn/error api logs  -> on the Shop Overview logs panel
  debug api logs            -> high volume, never queried (cold-storage candidate)
  audit logs                -> referenced by a Loki alert rule (hard keep)
"""

import json
import os
import random
import threading
import time
import urllib.request
import uuid

from prometheus_client import Counter, Gauge, Histogram, start_http_server

LOKI_URL = os.environ.get("LOKI_URL", "http://loki:3100").rstrip("/")
RPS = float(os.environ.get("REQUESTS_PER_SECOND", "20"))
PORT = int(os.environ.get("PORT", "8080"))
# Health checks per second across the simulated fleet (probers x replicas).
HEALTHCHECKS_PER_SECOND = float(os.environ.get("HEALTHCHECKS_PER_SECOND", "30"))
PROBES = ["kubelet-liveness", "kubelet-readiness", "alb-target-health"]
REPLICAS = [f"shop-{n}" for n in range(10)]

ROUTES = ["/", "/products", "/product/:id", "/cart", "/checkout", "/search", "/account"]
METHODS = {"/cart": ["GET", "POST", "DELETE"], "/checkout": ["POST"]}
USERS = [f"u{n:05d}" for n in range(2000)]
FLAGS = ["new_checkout", "dark_mode", "reco_v2", "fast_search", "promo_banner"]

# --- used -----------------------------------------------------------------
requests_total = Counter(
    "shop_http_requests", "HTTP requests.", ["method", "route", "status"])
request_duration = Histogram(
    "shop_http_request_duration_seconds", "HTTP request latency.", ["route"])
cart_ops = Counter(
    "shop_cart_operations", "Cart operations.", ["op", "user_id"])  # user_id: droppable label

healthchecks = Counter(
    "shop_healthcheck_checks", "Health checks served.", ["probe", "result"])
healthcheck_duration = Histogram(
    "shop_healthcheck_duration_seconds", "Health check latency.", ["probe"],
    buckets=(0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1))

# --- alert-only -----------------------------------------------------------
payment_queue = Gauge("shop_payment_queue_depth", "Payments waiting to be processed.")
# Read ONLY by a Grafana-managed alert (grafana/provisioning/alerting): no
# Prometheus rule, no dashboard. tvt must find it through Grafana's ruler API.
order_export_lag = Gauge(
    "shop_order_export_lag_seconds", "Seconds since orders were last exported to the warehouse.")

# --- declared-only (Sprint 2 item 7) -----------------------------------------
# Read ONLY by the Sloth SLO in slos/shop-checkout.sloth.yml (not loaded into
# Prometheus): no rule, no dashboard, no query. tvt must find it through the SLO.
checkout_attempts = Counter(
    "shop_checkout_attempts", "Checkout attempts by outcome.", ["outcome"])
# Read ONLY by a query step in runbooks/payment-queue-backlog.md, which
# ShopPaymentQueueBacklog links as its runbook_url.
gateway_retries = Counter(
    "shop_payment_gateway_retries", "Payment gateway calls retried.")

# --- stale dashboard ------------------------------------------------------
legacy_queue = Gauge("shop_legacy_queue_depth", "Legacy batch queue depth.")
legacy_batch = Gauge("shop_legacy_batch_duration_seconds", "Last legacy batch duration.")

# --- waste ----------------------------------------------------------------
CACHE_METRICS = [
    "evictions", "expirations", "size_bytes", "items", "get_latency_seconds",
    "set_latency_seconds", "connections", "connection_errors", "bytes_read",
    "bytes_written", "hits_ratio", "fragmentation_ratio", "keyspace_misses",
    "keyspace_hits", "rejected_connections", "blocked_clients", "pubsub_channels",
    "replication_lag_seconds", "rdb_changes_since_save", "aof_rewrite_seconds",
    "slowlog_length", "memory_peak_bytes", "memory_rss_bytes", "cpu_sys_seconds",
    "cpu_user_seconds", "commands_processed", "net_input_bytes", "net_output_bytes",
    "uptime_seconds", "lua_memory_bytes",
]
cache_gauges = {
    name: Gauge(f"shop_cache_{name}", f"Cache {name} (unused).", ["cache", "shard"])
    for name in CACHE_METRICS
}
cache_hits = Counter("shop_cache_hits", "Cache hits.")
cache_requests = Counter("shop_cache_requests", "Cache lookups.")
flag_evals = Counter(
    "shop_feature_flag_evaluations", "Feature flag evaluations.", ["flag", "variant", "user_id"])


# --- log shipping ---------------------------------------------------------
class LokiShipper:
    """Buffers log lines per stream and pushes them to Loki once a second."""

    def __init__(self, url):
        self.url = url + "/loki/api/v1/push"
        self.lock = threading.Lock()
        self.buf = {}

    def log(self, level, component, line):
        key = (level, component)
        entry = [str(time.time_ns()), line]
        with self.lock:
            self.buf.setdefault(key, []).append(entry)

    def run(self):
        while True:
            time.sleep(1)
            with self.lock:
                buf, self.buf = self.buf, {}
            if not buf:
                continue
            streams = [
                {"stream": {"app": "shop", "level": lvl, "component": comp}, "values": vals}
                for (lvl, comp), vals in buf.items()
            ]
            body = json.dumps({"streams": streams}).encode()
            req = urllib.request.Request(
                self.url, data=body, headers={"Content-Type": "application/json"})
            try:
                urllib.request.urlopen(req, timeout=5).read()
            except Exception as exc:  # Loki may not be up yet; drop and retry next batch
                print(f"loki push failed: {exc}", flush=True)


loki = LokiShipper(LOKI_URL)


def simulate_request():
    route = random.choice(ROUTES)
    method = random.choice(METHODS.get(route, ["GET"]))
    roll = random.random()
    status = "500" if roll < 0.01 else "404" if roll < 0.04 else "200"
    base = 0.35 if route == "/checkout" else 0.08
    duration = max(0.002, random.lognormvariate(0, 0.6) * base)
    req_id = uuid.uuid4().hex[:16]
    user = random.choice(USERS)

    requests_total.labels(method, route, status).inc()
    request_duration.labels(route).observe(duration)

    if route == "/checkout":
        checkout_attempts.labels("failure" if status == "500" else "success").inc()
        if random.random() < 0.1:
            gateway_retries.inc()
    if route == "/cart":
        cart_ops.labels({"GET": "view", "POST": "add", "DELETE": "remove"}[method], user).inc()
    for flag in random.sample(FLAGS, 2):
        flag_evals.labels(flag, random.choice(["on", "off"]), user).inc()
    cache_requests.inc()
    if random.random() < 0.83:
        cache_hits.inc()

    level = "error" if status == "500" else "warn" if status == "404" else "info"
    loki.log(level, "api",
             f'method={method} route={route} status={status} duration_ms={duration * 1000:.1f} '
             f'request_id={req_id} user={user}')

    # Debug noise: several verbose lines per request; the bulk of log bytes.
    for step in ("route-match", "auth", "db-query", "render"):
        payload = json.dumps({"step": step, "request_id": req_id, "headers": {
            "user-agent": "Mozilla/5.0 (lab)", "accept": "*/*",
            "x-trace": uuid.uuid4().hex}, "cache": {"hit": random.random() < 0.8}})
        loki.log("debug", "api", f"debug {payload}")

    if route in ("/checkout", "/account") or random.random() < 0.05:
        result = "denied" if random.random() < 0.03 else "allowed"
        loki.log("info", "audit",
                 f"action={route.strip('/') or 'home'} user={user} result={result} request_id={req_id}")


def simulate_healthcheck():
    probe = random.choice(PROBES)
    replica = random.choice(REPLICAS)
    ok = random.random() >= 0.005
    duration = max(0.0002, random.lognormvariate(0, 0.5) * 0.0008)
    healthchecks.labels(probe, "success" if ok else "failure").inc()
    healthcheck_duration.labels(probe).observe(duration)
    status = "200" if ok else "503"
    line = (f'method=GET route=/healthz status={status} duration_ms={duration * 1000:.2f} '
            f'probe={probe} replica={replica} request_id={uuid.uuid4().hex[:16]} user=-')
    # Successes land in the same info/api stream as real traffic; failures at warn.
    loki.log("info" if ok else "warn", "api", line if ok else line + " reason=db_ping_timeout")


def healthcheck_loop():
    if HEALTHCHECKS_PER_SECOND <= 0:
        return
    interval = 1.0 / HEALTHCHECKS_PER_SECOND
    while True:
        simulate_healthcheck()
        time.sleep(interval * random.uniform(0.5, 1.5))


def background_gauges():
    shards = [str(s) for s in range(16)]
    while True:
        payment_queue.set(max(0, random.gauss(20, 8)))
        order_export_lag.set(max(0, random.gauss(90, 30)))
        legacy_queue.set(max(0, random.gauss(300, 50)))
        legacy_batch.set(max(1, random.gauss(42, 5)))
        for g in cache_gauges.values():
            for cache in ("session", "catalog"):
                for shard in shards:
                    g.labels(cache, shard).set(random.random() * 1000)
        time.sleep(10)


def main():
    start_http_server(PORT)
    threading.Thread(target=loki.run, daemon=True).start()
    threading.Thread(target=background_gauges, daemon=True).start()
    threading.Thread(target=healthcheck_loop, daemon=True).start()
    print(f"shop: metrics on :{PORT}, logs to {LOKI_URL}, {RPS} req/s, "
          f"{HEALTHCHECKS_PER_SECOND} health checks/s", flush=True)
    interval = 1.0 / RPS if RPS > 0 else 1.0
    while True:
        simulate_request()
        time.sleep(interval * random.uniform(0.5, 1.5))


if __name__ == "__main__":
    main()
