# Uses `podman compose`. To use podman-compose directly: make COMPOSE=podman-compose up
COMPOSE ?= podman compose
# Live usage logs tvt scan reads (gitignored). Compose's logging paths must
# be absolute.
export LAB_LOGS := $(CURDIR)/lab-logs

.PHONY: up up-mimir cloud cloud-off down reset ps logs export-logs build lab-logs validate check-live urls autostart autostart-off

up: build lab-logs
	$(COMPOSE) up -d
	@$(MAKE) --no-print-directory urls

up-mimir: build lab-logs
	PROM_CONFIG=prometheus-mimir.yml $(COMPOSE) --profile mimir up -d
	@$(MAKE) --no-print-directory urls
	@echo "  Mimir         http://localhost:9009"

build:
	$(COMPOSE) build shop

# Prometheus (nobody) writes its query log into lab-logs/prometheus.
lab-logs:
	mkdir -p lab-logs/prometheus
	chmod 777 lab-logs/prometheus

# Forward a free-tier subset to the Grafana Cloud test stack
# (alloy/outputs/cloud.alloy), or stop. Recreates only Alloy (--no-deps:
# Prometheus keeps whichever config it runs). The GCLOUD_* variables come
# from your shell; a missing one stops here instead of Alloy failing on
# every send. The container keeps its mode across restarts and reboots;
# put ALLOY_OUTPUT=cloud in .env so a later make up keeps it too.
GCLOUD_VARS := GCLOUD_HOSTED_METRICS_URL GCLOUD_HOSTED_METRICS_ID GCLOUD_HOSTED_LOGS_URL GCLOUD_HOSTED_LOGS_ID GCLOUD_RW_API_KEY
cloud: lab-logs
	@for v in $(GCLOUD_VARS); do \
		eval "x=\$${$$v}"; [ -n "$$x" ] || { echo "$$v is not set (export it in your shell)" >&2; exit 1; }; \
	done
	ALLOY_OUTPUT=cloud $(COMPOSE) up -d --no-deps alloy

cloud-off: lab-logs
	ALLOY_OUTPUT=local $(COMPOSE) up -d --no-deps alloy

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

# The Prometheus query log and the Loki and Mimir logs are already live in
# ./lab-logs. Grafana's file log lives on its data volume: copy it.
#   tvt scan ... --prom-query-log lab-logs/prometheus/query.log \
#     --loki-query-log lab-logs/loki.log --grafana-log 'lab-logs/grafana.log*'
export-logs: lab-logs
	$(COMPOSE) exec -T grafana sh -c 'cd /var/lib/grafana/logs && tar cf - grafana.log*' | tar xf - -C lab-logs
	@ls -l lab-logs

# Validate configs with the tools baked into the images.
validate:
	podman run --rm -v ./prometheus:/etc/prometheus:ro --entrypoint promtool \
		docker.io/prom/prometheus:v3.5.0 check config /etc/prometheus/prometheus.yml
	podman run --rm -v ./prometheus/rules:/rules:ro --entrypoint promtool \
		docker.io/prom/prometheus:v3.5.0 check rules /rules/shop.yml /rules/healthcheck.yml
	podman run --rm -v ./loki/loki.yml:/etc/loki/loki.yml:ro \
		docker.io/grafana/loki:3.5.3 -config.file=/etc/loki/loki.yml -verify-config
	podman run --rm -v ./alertmanager:/etc/alertmanager:ro --entrypoint amtool \
		docker.io/prom/alertmanager:v0.28.1 check-config /etc/alertmanager/alertmanager.yml
	podman run --rm -v ./fluent-bit/fluent-bit.yaml:/fluent-bit/etc/fluent-bit.yaml:ro \
		docker.io/fluent/fluent-bit:5.2.0 -c /fluent-bit/etc/fluent-bit.yaml --dry-run
	for o in local cloud; do \
		podman run --rm -e TVT_LAB_SPANS_DROP_REGEX=tvt_lab_env_no_such_metric \
			-v ./alloy/config.alloy:/run/alloy/config.alloy:ro \
			-v ./alloy/outputs/$$o.alloy:/run/alloy/output.alloy:ro \
			docker.io/grafana/alloy:v1.10.0 validate /run/alloy || exit 1; \
	done

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
	@echo "  Alloy         http://localhost:12345"
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
