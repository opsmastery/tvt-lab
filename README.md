# tvt-lab

A Podman-based Grafana stack seeded with **known telemetry waste** and **known dependencies**. [Telemetry Value Tracker](../tvt) is developed and tested against it. [`ground-truth.yaml`](ground-truth.yaml) lists what tvt should conclude about every signal.

## What's in it

| Service | Port | Role |
| --- | --- | --- |
| Grafana 12 (OSS) | 3000 | Two dashboards: *Shop Overview* (viewed) and *Legacy Queue* (never viewed) |
| Prometheus 3.5 | 9090 | 10s scrapes, query log on, recording and alerting rules |
| Loki 3.5 | 3100 | Shop log streams, a ruler alert on the audit stream, volume API on |
| Alertmanager | 9093 | Receives alerts, routes them nowhere |
| node-exporter | 9100 | Hundreds of metrics, two of them used |
| shop | 8080 | Seeded Python app: used, alert-only, stale and wasted metrics, plus info/debug/audit logs |
| viewer | | Replays Shop Overview panel queries through Grafana with dashboard/panel headers, plus occasional ad hoc queries |
| Mimir 2.16 | 9009 | Optional (`make up-mimir`): remote-write target, cardinality API, query-frontend logging |

## Run it

You need Podman 5+ and a compose provider (`podman compose` uses docker-compose or podman-compose). On macOS, give the Podman machine at least 4 GB of memory:

```sh
podman machine init --memory 6144 --cpus 4   # first time only
podman machine start
make up          # or: make up-mimir
make validate    # check the Prometheus, Loki and Alertmanager configs with their own tools
```

Leave it running. tvt's confidence model wants **30 days** of history, and Prometheus and Loki keep 45. `make down` stops the stack and keeps the data. `make reset` deletes it.

On macOS, run `make autostart` once. It enables `podman-restart.service` in the Podman VM, so the containers come back whenever the VM boots, and installs a LaunchAgent that starts the VM at login. Sleep still pauses the VM and leaves gaps in the history, so keep the Mac awake while it's on power (System Settings > Battery > Options > "Prevent automatic sleeping when the display is off"). `make autostart-off` removes the LaunchAgent.

To scan the lab with `tvt scan`, run `make export-logs` first. It copies the Prometheus query log and Grafana's file log (`grafana.log*`) into `./lab-logs` (gitignored) for `--prom-query-log` and `--grafana-log`.

On Linux with SELinux enforcing, add `:Z` to the bind mounts in `compose.yaml`.

## Point tvt at it

```sh
tvt scan --grafana http://localhost:3000 --prom http://localhost:9090 --loki http://localhost:3100
```

For the Grafana API, create a Viewer service account under **Administration → Users and access → Service accounts** and export its token as `TVT_GRAFANA_TOKEN`.

## Where the usage evidence lives (Phase 0 spikes)

| Evidence | Where to look |
| --- | --- |
| Prometheus query log | `podman compose exec prometheus cat /prometheus/query.log` |
| Loki query stats | `podman compose logs loki` (lines containing `metrics.go`) |
| Grafana router log (dashboard loads) | `podman compose logs grafana \| grep 'path=/api/dashboards/uid/'` |
| Mimir query stats (with dashboard and panel headers) | `podman compose logs mimir \| grep 'msg="query stats"'` |
| Loki bytes per stream | `curl -G localhost:3100/loki/api/v1/index/volume --data-urlencode 'query={app="shop"}'` |
| Prometheus cardinality | `curl localhost:9090/api/v1/status/tsdb` |
| Mimir cardinality | `curl 'localhost:9009/prometheus/api/v1/cardinality/label_names'` |

## The seeded scenario

See [`ground-truth.yaml`](ground-truth.yaml). In short:

- **Hard keeps:** `shop_http_requests_total` (error-rate alert), histogram buckets that feed a latency alert through a recording rule, the alert-only `shop_payment_queue_depth`, and the audit log stream (Loki alert).
- **Used:** the Shop Overview panels, plus one ad hoc node-memory query.
- **Waste:** 960 `shop_cache_*` series, high-cardinality feature-flag counters, `_created` series, a recording rule nobody uses, most node-exporter metrics, the `user_id` label on cart operations, and the debug log stream (about 88% of log bytes).

## Versions

Images are pinned in `compose.yaml` and `Makefile`. Bump them together.
