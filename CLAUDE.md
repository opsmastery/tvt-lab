# tvt-lab

A Podman Compose Grafana stack seeded with known telemetry waste and known dependencies: the test bed for `../tvt`. `ground-truth.yaml` is the expected classification of every signal. Keep it in sync with any change to `shop/app.py`, the rules or the dashboards.

- `make up` / `make up-mimir` / `make down` / `make validate` / `make autostart` (macOS: restart on VM boot + VM at login). Never `make reset` casually: tvt needs 30+ days of history.
- Image versions are pinned in both `compose.yaml` and `Makefile`. Bump them together.
- Use fully qualified image names (`docker.io/...`) so Podman doesn't prompt for short-name resolution.
- Grafana is plain HTTP on http://localhost:3000 (admin/admin).
- The `viewer` service simulates browser views of the Shop Overview dashboard only. Legacy Queue must stay unviewed.
- Grafana-managed alert: `shop_order_export_lag_seconds` is read only by the provisioned rule in `grafana/provisioning/alerting/shop-alerts.yml`. Ground truth expects it as hard_keep.
- Mimir profile: the one-shot `mimir-rules` service (curl) loads `mimir/rules/shop.yml` into Mimir's ruler, namespace `tvt-lab`, on every `make up-mimir`. Its recording rules copy `shop-recording` with a `ruler: mimir` label so they don't collide with the series Prometheus remote-writes. `NodeLoadHigh` makes `node_load15` hard_keep for a `--mimir` scan only (`mimir:` in ground truth). The ruler picks up new rules within about a minute.
- The /healthz scenario: successful health checks are logged into the same info/api stream as real traffic (about 64% of its bytes). Ground truth expects tvt to report the pattern and hand it to zeroreads (`line_handoff`), not to generate a line filter or touch the stream. Loki's pattern ingester is enabled for this.
- Declared-only metrics (tvt Sprint 2 item 7): `shop_checkout_attempts_total` is read only by the Sloth SLO in `slos/` (not loaded into Prometheus), and `shop_payment_gateway_retries_total` only by the query step in `runbooks/payment-queue-backlog.md`, which `ShopPaymentQueueBacklog` links as its `runbook_url`. Both are hard_keep. After changing the shop: `podman compose up -d --build shop`; after changing rules: `curl -X POST localhost:9090/-/reload`.
