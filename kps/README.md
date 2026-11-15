# kps: kube-prometheus-stack on kind

A single-node kind cluster (Podman) running [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack), pinned to chart 93.3.0. It gives tvt the Kubernetes setup most teams run, in two ways:

- **Fixtures** (`make fixtures`, no cluster): the rendered rules, ServiceMonitors, PodMonitors and dashboards plus the chart's default values, for tvt's S5 to S8 tests.
- **Grafana Cloud** (`make cloud`): a free-tier subset remote-written to the Cloud test stack, labeled `cluster="tvt-kps"`, beside tvt-lab's own Alloy output.

## Run it

```sh
cd kps
make up                 # kind cluster tvt-kps + the chart, local only
make series             # local series by job, and what Cloud would get
make cloud-secret       # remote-write Secret from GCLOUD_HOSTED_METRICS_ID and GCLOUD_RW_API_KEY
make cloud              # turn on remote write (values-cloud.yaml)
make cloud-off          # back to local only
make down               # delete the cluster
```

Needs `kind`, `helm`, `kubectl` and a Podman machine with about 8 GB (tvt-lab and this cluster together). `make up` switches kubectl's current context to `kind-tvt-kps`.

## Free-tier budget

The free tier allows 10k active series. tvt-lab's `make cloud` uses about 7k, so `values-cloud.yaml` keeps about 2.3k of the cluster's ~35k: kube-state-metrics, core cAdvisor and node-exporter metrics, `apiserver_request_total`, recording rule outputs, `ALERTS` and `up`. `make series` fails if the filter goes over 2,500. Two metrics are kept with no reader in the bundled rules or dashboards (`container_memory_max_usage_bytes`, `container_threads`) so a Cloud scan has waste to find.

## Notes

- Grafana is off. tvt reads dashboards from the Cloud stack; import the chart's dashboards there if a scan needs them.
- The chart's rules run in the local Prometheus, not the Cloud ruler. Their outputs reach Cloud as series.
- On kind, the etcd, controller-manager, scheduler and kube-proxy targets are down (they listen on 127.0.0.1), so their alerts fire constantly. Left as shipped: a realistic source of alert noise.
- Prometheus logs queries to `/var/log/prometheus/query.log` for tvt's query evidence.
