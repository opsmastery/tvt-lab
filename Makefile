# Uses `podman compose`. To use podman-compose directly: make COMPOSE=podman-compose up
COMPOSE ?= podman compose

.PHONY: up up-mimir down reset ps logs export-logs build validate check-live urls autostart autostart-off

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

# Copy the usage logs tvt scan reads to ./lab-logs:
#   tvt scan ... --prom-query-log lab-logs/query.log --grafana-log 'lab-logs/grafana.log*'
export-logs:
	mkdir -p lab-logs
	$(COMPOSE) exec -T prometheus cat /prometheus/query.log > lab-logs/query.log
	$(COMPOSE) exec -T grafana sh -c 'cd /var/lib/grafana/logs && tar cf - grafana.log*' | tar xf - -C lab-logs
	@ls -l lab-logs

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

# Is the running lab what the repo describes? Every rule and Grafana alert
# on disk must be loaded (Grafana reads alert provisioning only at start).
check-live:
	./scripts/check-live.sh

urls:
	@echo ""
	@echo "  Grafana       http://localhost:3000  (admin / admin)"
	@echo "  Prometheus    http://localhost:9090"
	@echo "  Loki          http://localhost:3100"
	@echo "  Alertmanager  http://localhost:9093"
	@echo "  Shop metrics  http://localhost:8080/metrics"

# Keep the lab collecting across reboots (macOS):
#  - inside the Podman VM, podman-restart.service restarts restart-policy
#    containers when the VM boots;
#  - a LaunchAgent starts the VM at login.
# Sleep still pauses the VM: on power, enable "Prevent automatic sleeping
# when the display is off" (System Settings > Battery > Options).
PLIST := com.opsmastery.podman-machine.plist

autostart:
	podman machine ssh -- sudo systemctl enable podman-restart.service
	cp macos/$(PLIST) ~/Library/LaunchAgents/$(PLIST)
	launchctl bootstrap gui/$$(id -u) ~/Library/LaunchAgents/$(PLIST) 2>/dev/null || true
	@echo "autostart on: VM starts at login, containers restart with the VM"

autostart-off:
	-launchctl bootout gui/$$(id -u)/com.opsmastery.podman-machine
	rm -f ~/Library/LaunchAgents/$(PLIST)
