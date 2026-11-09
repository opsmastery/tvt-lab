# Uses `podman compose`. To use podman-compose directly: make COMPOSE=podman-compose up
COMPOSE ?= podman compose

.PHONY: up up-mimir down reset ps logs build validate urls

up: build
	$(COMPOSE) up -d
	@$(MAKE) --no-print-directory urls

up-mimir: build
	PROM_CONFIG=prometheus-mimir.yml $(COMPOSE) --profile mimir up -d
	@$(MAKE) --no-print-directory urls
	@echo "  Mimir         http://localhost:9009"

build:
	$(COMPOSE) build shop

down:
	$(COMPOSE) --profile mimir down

# Deletes all stored metrics and logs. tvt needs 30 days of history, so only
# do this when you mean it.
reset:
	$(COMPOSE) --profile mimir down -v

ps:
	$(COMPOSE) ps

logs:
	$(COMPOSE) logs -f --tail=50

# Validate configs with the tools baked into the images.
validate:
	podman run --rm -v ./prometheus:/etc/prometheus:ro --entrypoint promtool \
		docker.io/prom/prometheus:v3.5.0 check config /etc/prometheus/prometheus.yml
	podman run --rm -v ./prometheus/rules:/rules:ro --entrypoint promtool \
		docker.io/prom/prometheus:v3.5.0 check rules /rules/shop.yml
	podman run --rm -v ./loki/loki.yml:/etc/loki/loki.yml:ro \
		docker.io/grafana/loki:3.5.3 -config.file=/etc/loki/loki.yml -verify-config
	podman run --rm -v ./alertmanager:/etc/alertmanager:ro --entrypoint amtool \
		docker.io/prom/alertmanager:v0.28.1 check-config /etc/alertmanager/alertmanager.yml

urls:
	@echo ""
	@echo "  Grafana       http://localhost:3000  (admin / admin)"
	@echo "  Prometheus    http://localhost:9090"
	@echo "  Loki          http://localhost:3100"
	@echo "  Alertmanager  http://localhost:9093"
	@echo "  Shop metrics  http://localhost:8080/metrics"
