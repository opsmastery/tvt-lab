# tvt-lab

A Podman Compose Grafana stack seeded with known telemetry waste and known dependencies: the test bed for `../tvt`. `ground-truth.yaml` is the expected classification of every signal. Keep it in sync with any change to `shop/app.py`, the rules or the dashboards.

- `make up` / `make up-mimir` / `make down` / `make validate` / `make autostart` (macOS: restart on VM boot + VM at login). Never `make reset` casually: tvt needs 30+ days of history.
- Image versions are pinned in both `compose.yaml` and `Makefile`. Bump them together.
- Use fully qualified image names (`docker.io/...`) so Podman doesn't prompt for short-name resolution.
- Grafana is plain HTTP on http://localhost:3000 (admin/admin).
- The `viewer` service simulates browser views of the Shop Overview dashboard only. Legacy Queue must stay unviewed.
