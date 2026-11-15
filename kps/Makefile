# kube-prometheus-stack on a kind cluster (Podman), optionally remote-writing
# a free-tier subset to the Grafana Cloud test stack. Run from kps/.
#
#   make up            create the tvt-kps kind cluster and install the chart
#   make cloud-secret  create the remote-write Secret from your shell's
#                      GCLOUD_HOSTED_METRICS_ID and GCLOUD_RW_API_KEY
#   make cloud         add remote write to Cloud (values-cloud.yaml)
#   make cloud-off     back to local only
#   make series        local series by job, and what the Cloud filter keeps
#   make fixtures      render the pinned chart into fixtures/ (no cluster)
#   make down          delete the cluster

KPS_VERSION ?= 93.3.0
CTX         := kind-tvt-kps
NS          := monitoring
HELM        := helm --kube-context $(CTX)
KUBECTL     := kubectl --context $(CTX)
export KIND_EXPERIMENTAL_PROVIDER := podman

.PHONY: up repo install cloud-secret cloud cloud-off series fixtures down

up:
	@kind get clusters 2>/dev/null | grep -qx tvt-kps || kind create cluster --config kind.yaml
	$(MAKE) install

repo:
	@helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
	@helm repo update prometheus-community >/dev/null

install: repo
	$(HELM) upgrade --install kps prometheus-community/kube-prometheus-stack --version $(KPS_VERSION) \
	  -n $(NS) --create-namespace -f values.yaml --wait --timeout 10m

# Reads the credentials from the environment and pipes them straight to
# kubectl; they never land in a file or this repo.
cloud-secret:
	@test -n "$$GCLOUD_HOSTED_METRICS_ID" && test -n "$$GCLOUD_RW_API_KEY" || { echo "set GCLOUD_HOSTED_METRICS_ID and GCLOUD_RW_API_KEY first"; exit 1; }
	@$(KUBECTL) -n $(NS) create secret generic grafana-cloud-metrics \
	  --from-literal=username="$$GCLOUD_HOSTED_METRICS_ID" --from-literal=password="$$GCLOUD_RW_API_KEY" \
	  --dry-run=client -o yaml | $(KUBECTL) apply -f - >/dev/null && echo "grafana-cloud-metrics secret applied"

cloud: repo
	@test -n "$$GCLOUD_HOSTED_METRICS_URL" || { echo "set GCLOUD_HOSTED_METRICS_URL first"; exit 1; }
	@$(KUBECTL) -n $(NS) get secret grafana-cloud-metrics >/dev/null 2>&1 || { echo "run make cloud-secret first"; exit 1; }
	$(HELM) upgrade --install kps prometheus-community/kube-prometheus-stack --version $(KPS_VERSION) \
	  -n $(NS) -f values.yaml -f values-cloud.yaml \
	  --set "prometheus.prometheusSpec.remoteWrite[0].url=$$GCLOUD_HOSTED_METRICS_URL" --wait --timeout 10m

cloud-off: install

series:
	@python3 scripts/series.py

fixtures: repo
	@rm -rf fixtures && mkdir -p fixtures
	helm template kps prometheus-community/kube-prometheus-stack --version $(KPS_VERSION) -n $(NS) -f values.yaml > fixtures/rendered.yaml
	helm show values prometheus-community/kube-prometheus-stack --version $(KPS_VERSION) > fixtures/chart-values.yaml
	@echo "fixtures/ rendered from chart $(KPS_VERSION)"

down:
	kind delete cluster --name tvt-kps
