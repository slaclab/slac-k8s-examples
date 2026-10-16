# Monitoring (the platform Prometheus and Grafana)

The platform runs one Prometheus for the whole host cluster. It records the CPU, memory, restarts
and disk use of every pod, yours included, and keeps the data for a year. You do not run a
Prometheus of your own for these metrics, and you do not need to do anything for them to exist.
To have your application's own metrics scraped, annotate its pods (this guide) or create a
ServiceMonitor or PodMonitor ([ServiceMonitor and PodMonitor](../serviceMonitor/README.md)). A
HorizontalPodAutoscaler cannot scale on these metrics: for `kubectl top` and autoscaling on CPU
and memory, see [Resource metrics](../autoscaling/README.md).

Annotation scraping works in every vcluster. ServiceMonitors and PodMonitors leave your vcluster
only if the platform team has turned on the Prometheus monitors switch for it (on by default for
new vclusters); see [Your vcluster](../vcluster/README.md#features-and-allowlists-the-platform-sets).

## Where to look

| Tool | Address | Access | What it is for |
|---|---|---|---|
| Prometheus | `https://prometheus.slac.stanford.edu` | SLAC networks only, no login | PromQL queries and graphs; your scrape targets under Status, Target health |
| Grafana | `https://grafana.slac.stanford.edu` | SLAC SSO | Dashboards and alert rules |

Grafana gives a new user the Viewer role: you can open dashboards. To build dashboards or alert
rules you need edit rights, the Editor role or edit permission on a folder, which a Grafana
administrator grants: ask the platform team (s3df-help). Build dashboards in the Grafana UI:
Grafana does not load dashboards from ConfigMaps.

Prometheus is not partitioned per tenant: anyone who can reach it can query the series of every
vcluster, yours included. Don't put secrets or personal data in label values.

## Which series are yours

Prometheus scrapes the host cluster, where your objects carry their host names
([Names on the host](../vcluster/README.md#names-on-the-host)). Filter on these labels:

| Label | Value for your vcluster | Notes |
|---|---|---|
| `namespace` | `vcluster--<name>`, your host namespace | The same for every namespace inside your vcluster |
| `pod` | `<pod>-x-<namespace>-x-vcluster--<name>` | A name longer than 63 characters is cut to its first 52 characters, a dash and a 10-character hash |
| `container` | The container name | Unchanged |

Your series do not carry the namespace inside your vcluster: tell your applications apart by
their pod labels, or by the `pod` name, which contains it. Series scraped through pod annotations
carry the labels of the pod, with each character that is not a letter, digit or underscore
replaced by `_`: `app.kubernetes.io/name` becomes `app_kubernetes_io_name`. A pod label `release`
is the exception: your vcluster renames it on the host, so it never reaches the series. For the
labels of series scraped through a ServiceMonitor or PodMonitor, see
[What the series look like](../serviceMonitor/README.md#what-the-series-look-like). To list your
scrape targets, query `up{namespace="vcluster--<name>"}` (see [Checking](#checking)).

## Metrics you get without doing anything

| Source | Series | What they tell you |
|---|---|---|
| cAdvisor (the kubelet) | `container_cpu_usage_seconds_total`, `container_memory_working_set_bytes`, `container_network_*`, ... | CPU and memory per container, network traffic per pod |
| kube-state-metrics | `kube_pod_status_phase`, `kube_pod_container_status_restarts_total`, `kube_pod_container_status_last_terminated_reason`, `kube_persistentvolumeclaim_*`, ... | Pod state, restarts, OOM kills, claims |
| The kubelet | `kubelet_volume_stats_used_bytes`, `kubelet_volume_stats_capacity_bytes` | Space used in volumes whose storage driver reports it: ZFS volumes do, Weka volumes do not |
| k8s-ephemeral-storage-metrics | `ephemeral_storage_pod_usage`, `ephemeral_storage_container_limit_percentage` | Disk used by the pod's logs, writable layers and `emptyDir` volumes, and that use as a percentage of each container's ephemeral-storage limit. See [Requests, limits, QoS and ephemeral storage](../resources/README.md) |

The Weka driver reports no volume use to the kubelet, so a Weka claim has no
`kubelet_volume_stats_*` series. Check its use with `df -h` on the mount path, in a pod that
mounts it.

The ephemeral-storage series name your pod in their own labels, `pod_namespace` and `pod_name`,
and the container in `exported_container`; their `namespace` and `pod` labels point at the
exporter itself. Filter them on `pod_namespace="vcluster--<name>"`. For a container without an
ephemeral-storage limit, `ephemeral_storage_container_limit_percentage` holds the node's free
space in percent instead, so set limits on containers that write files.

Deployments, StatefulSets, Jobs and CronJobs exist only inside your vcluster, so there are no
`kube_deployment_*`, `kube_statefulset_*` or `kube_job_*` series for your workloads. Work from the
`kube_pod_*` series and group by `pod`: the host pod name starts with your pod's name (its first 52
characters, for a long name).

Kubelet series such as `kubelet_volume_stats_used_bytes` are also collected by a second job,
`kubernetes-nodes`. Add `job="kubelet"` to queries on kubelet and cAdvisor series, so that a `sum`
counts each series once.

## Scraping your application with annotations

Add `prometheus.io` annotations to the pod template of a Deployment, StatefulSet or DaemonSet.
The vcluster syncs the pods, with their annotations and labels, to the host, where the platform
Prometheus discovers them in every namespace. Nothing else is needed: no CRD, no switch, and Helm
charts that set these annotations on their pods work as they are.

| Annotation on the pod template | Value | What it is for |
|---|---|---|
| `prometheus.io/scrape` | `"true"` | Scrape the pod every 30 seconds |
| `prometheus.io/scrape_slow` | `"true"` | Scrape the pod every 5 minutes, with a 30-second timeout, for expensive exporters. Replaces `prometheus.io/scrape` |
| `prometheus.io/port` | The port, for example `"8080"` | Which port to scrape. Without it, every declared container port is scraped |
| `prometheus.io/path` | Default `/metrics` | The metrics path |
| `prometheus.io/scheme` | `http` (default) or `https` | |
| `prometheus.io/param_<name>` | A value | Adds `?<name>=<value>` to the scrape URL |

Values are strings, so quote them: `"true"`, `"8080"`. Pods that are `Pending`, `Succeeded` or
`Failed` are not scraped, so a Job's pod is scraped only while it runs, and one that finishes
before its first scrape is never scraped; see [Jobs and CronJobs](../jobs/README.md). These jobs
keep the labels an exporter emits: if your application emits its own `namespace`, `pod` or `job`
label, that value replaces the one above.

The same annotations exist for Services, but only `prometheus.io/scrape_slow` behaves like the pod
version (every 5 minutes, honouring port, path and scheme, with the Service's labels and
`namespace`). `prometheus.io/scrape: "true"` on a Service scrapes every port of every pod behind
the Service at `/metrics` over HTTP, ignores `prometheus.io/port` and `prometheus.io/path`, and
labels the series with `job` and `instance` only, so you cannot find them by vcluster. Annotate
pods, not Services, or use a ServiceMonitor.

## Retention

Prometheus keeps every series for 365 days. It runs as a single instance, so a restart or
upgrade of Prometheus leaves a short gap in every series. The platform also copies the data to
object storage with Thanos; Thanos has no address for tenants to open.

## Alerting

The platform runs no Alertmanager, and PrometheusRule and AlertmanagerConfig objects in your
vcluster are not synced to the host, so the platform Prometheus never evaluates them. Define
alerts as Grafana alert rules on `grafana.slac.stanford.edu`; Grafana can send them by email.
This needs edit rights in Grafana (see [Where to look](#where-to-look)).

## Examples

| File | What it shows |
|---|---|
| [`deployment-scrape.yaml`](deployment-scrape.yaml) | A Deployment whose pods are scraped every 30 seconds through annotations on the pod template |
| [`service.yaml`](service.yaml) | The Service in front of it, without scrape annotations |
| [`deployment-scrape-slow.yaml`](deployment-scrape-slow.yaml) | An exporter scraped every 5 minutes with `prometheus.io/scrape_slow` |

The manifests set no namespace. Apply them to a namespace of your own with `-n`: platform policy
forbids the vcluster's `default` namespace, and [Your vcluster](../vcluster/README.md) shows how
to create one. For the same application scraped through a ServiceMonitor or PodMonitor, see
[ServiceMonitor and PodMonitor](../serviceMonitor/README.md).

## Mistakes that lose or hide metrics

| Mistake | Result |
|---|---|
| Annotations on the Deployment's own `metadata` instead of the pod template | Nothing is scraped |
| `prometheus.io/scrape: true` or `prometheus.io/port: 8080` without quotes | `kubectl apply` refuses the manifest: annotation values must be strings |
| `prometheus.io/scrape: "true"` on a Service | Every port is scraped at `/metrics`, port and path annotations are ignored, and the series carry no `namespace` label |
| No `prometheus.io/port` on a pod with several container ports | Every port is scraped; the ones that are not metrics endpoints fail, and `up` shows them as down |
| `prometheus.io/scrape` and `prometheus.io/scrape_slow` both on a pod | Only the slow job scrapes it. On a Service, both jobs scrape it |
| Annotations and a ServiceMonitor or PodMonitor for the same pods | Scraped twice |
| `prometheus.io/probe: "true"` | No probe results: the platform runs no blackbox exporter for this annotation |
| A PrometheusRule or AlertmanagerConfig in your vcluster | The platform Prometheus never sees it, so no alert fires. Use Grafana alert rules |
| Filtering on your vcluster namespace, for example `namespace="my-namespace"` | No series. Use `namespace="vcluster--<name>"` and your pod labels |
| Filtering on a pod label `release` | No series: the label never reaches Prometheus. Use another label, such as `app` |
| A `sum` over kubelet or cAdvisor series without `job="kubelet"` | Kubelet series are counted twice |
| Looking for `kubelet_volume_stats_*` of a Weka claim | No series: the Weka driver does not report volume use. Use `df -h` in a pod |
| A pod label that changes often, such as a build or request id | Every value is a new series: with annotation scraping, the pod labels become metric labels |
| An annotated exporter that emits `namespace`, `pod` or `job` labels | Its values replace the host labels, so the series leave your vcluster's filter |
| A secret, token or password in a label value | Visible to everyone who can reach Prometheus |

## Checking

```bash
kubectl apply -n my-namespace -f deployment-scrape.yaml -f service.yaml

# The pods run and carry the annotations (not only the Deployment).
kubectl get pods -n my-namespace -l app=my-app \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.metadata.annotations}{"\n"}{end}'

# The application answers on the annotated port and path.
kubectl run -n my-namespace curl --rm -it --restart=Never --image=curlimages/curl:8.13.0 -- \
  -s http://my-app.my-namespace.svc.cluster.local:8080/metrics

# One request to the application, so that its request counter has a series.
kubectl run -n my-namespace curl --rm -it --restart=Never --image=curlimages/curl:8.13.0 -- \
  -s http://my-app.my-namespace.svc.cluster.local:8080/
```

Then, in the Prometheus UI (replace `my-vcluster` with your vcluster's name):

```promql
# Your scrape targets, and whether the last scrape worked (1) or failed (0).
up{namespace="vcluster--my-vcluster"}

# The example application's request counter, after the request above.
http_requests_total{namespace="vcluster--my-vcluster", app="my-app"}

# CPU and memory per pod, from cAdvisor.
sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="vcluster--my-vcluster", container!="", job="kubelet"}[5m]))
sum by (pod) (container_memory_working_set_bytes{namespace="vcluster--my-vcluster", container!="", job="kubelet"})

# Restarts and OOM kills.
kube_pod_container_status_restarts_total{namespace="vcluster--my-vcluster"}
kube_pod_container_status_last_terminated_reason{namespace="vcluster--my-vcluster", reason="OOMKilled"}

# Space used in your ZFS volumes (Weka volumes are not reported).
kubelet_volume_stats_used_bytes{namespace="vcluster--my-vcluster", job="kubelet"}

# Ephemeral storage: each pod's use as a percentage of each container's limit.
ephemeral_storage_container_limit_percentage{pod_namespace="vcluster--my-vcluster"}
```

A new target appears in `up` within a minute of the pod starting, and within 5 minutes with
`prometheus.io/scrape_slow`. A target that is missing was never discovered: check that the
annotations are on the pod, not the Deployment. A target with `up == 0` was discovered but the
scrape failed: check the port and path.

Upstream reference: [Prometheus querying basics](https://prometheus.io/docs/prometheus/latest/querying/basics/)
and [Grafana alerting](https://grafana.com/docs/grafana/latest/alerting/).
