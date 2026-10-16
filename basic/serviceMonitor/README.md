# ServiceMonitor and PodMonitor (Prometheus Operator)

A ServiceMonitor or PodMonitor tells the platform Prometheus to scrape your application's
metrics. A ServiceMonitor selects Services and scrapes every endpoint behind them; a PodMonitor
selects pods and needs no Service. You write either one inside your vcluster, and the platform's
single Prometheus scrapes your pods. You run no Prometheus of your own. Where the metrics go, how
long they are kept and how to query them is in [Monitoring](../monitoring/README.md).

Monitors leave your vcluster only if the platform team has turned on the Prometheus switch for
your vcluster. It is on by default for new vclusters, but older ones may not have it. Without it,
the `ServiceMonitor` and `PodMonitor` kinds do not exist in your vcluster, and `kubectl apply`
answers `no matches for kind "ServiceMonitor"`. Ask the platform team (s3df-help) to turn it on;
see [Your vcluster](../vcluster/README.md#features-and-allowlists-the-platform-sets).

## How a monitor reaches Prometheus

Write the monitor inside your vcluster, next to the Service or pods it selects. The platform
does the rest:

1. Your vcluster copies the monitor to the host cluster. The copy is named
   `<monitor>-x-<namespace>-x-vcluster--<vcluster>`, like every synced object (see
   [Names on the host](../vcluster/README.md#names-on-the-host)).
2. On the copy, the platform adds the label the platform Prometheus selects monitors by
   (`release: sdf-k8s01`), so the monitor needs no label of yours. This is how one Prometheus
   picks up monitors from every vcluster without tenants setting the label themselves.
3. The platform replaces `namespaceSelector` with "the monitor's own namespace". On the host that
   is `vcluster--<vcluster>`, where all of your namespaces land, so a monitor cannot select
   Services or pods of another vcluster.
4. `selector` is copied unchanged. Host copies of your Services and pods keep your label keys,
   so the same `matchLabels` match on the host. The exception is the `release` label, which the
   host copy carries under a rewritten key, so never select on `release`.
5. The Secret that an endpoint's `authorization.credentials` references (see
   [Settings](#settings)) is copied to the host next to the monitor.
6. The platform Prometheus discovers the targets and scrapes them, every 30 seconds unless the
   endpoint sets `interval`. Platform network policies always let Prometheus reach your pods,
   even in a vcluster with network isolation.

The platform Prometheus is the only one. It also has no sample or target limits: a monitor that
produces millions of series slows it down for every tenant. Keep label cardinality low (no user
IDs, request paths or pod-template hashes as label values), and never put secrets or personal
data in metric labels or values, because everyone on the SLAC network can query the metrics.

## Settings

| Field | Value | What it is for |
|---|---|---|
| `spec.selector.matchLabels` | Labels of your Services (ServiceMonitor) or pods (PodMonitor) | Chooses the targets. It matches in every namespace of your vcluster, so use a label value that is unique to the application. Don't use the `release` label |
| `spec.endpoints[].port` (ServiceMonitor) | The Service port **name**, for example `metrics` | Which port to scrape. A number is not accepted here; use `targetPort` for a port number |
| `spec.podMetricsEndpoints[].port` (PodMonitor) | The container port **name** declared in the pod spec | Which port to scrape. A pod without a port of that name gives no target |
| `path` | Default `/metrics` | The HTTP path of the metrics |
| `interval` | Default `30s` | How often the endpoint is scraped |
| `scheme`, `tlsConfig` | `scheme: https` | HTTPS endpoints. See below for Secret and ConfigMap references in `tlsConfig` |
| `authorization.credentials` | A Secret key in the monitor's namespace | A token for the `Authorization` header, `Bearer` by default. See [`serviceMonitor-authorization.yaml`](serviceMonitor-authorization.yaml) |
| `metricRelabelings`, `relabelings` | | Drop or rename series and labels before they are stored |
| `spec.namespaceSelector` | Leave it out | Replaced by the platform; whatever you write is ignored |
| `spec.jobLabel`, `spec.targetLabels`, `spec.podTargetLabels` (ServiceMonitor), `spec.jobLabel` (PodMonitor) | Leave them out | The platform rewrites these label keys on the host copy to keys that host copies of your Services and pods do not carry, so they have no effect |
| `spec.podTargetLabels` (PodMonitor) | Pod label keys | Copies those pod labels onto the series. The platform leaves this field unchanged, and host pods keep your label keys |

Your vcluster copies a Secret to the host only when something on the host needs it, so the
platform copies the Secret that `authorization.credentials` names and leaves your other Secrets
in the vcluster. `basicAuth`, `bearerTokenSecret`, `oauth2` and `tlsConfig.keySecret` point at
Secrets that are not copied, so they do not work. Give the application a token and use
`authorization.credentials` instead. References in `tlsConfig.ca` and `tlsConfig.cert` are not
confirmed to reach the host; ask the platform team (s3df-help) before relying on them.

## What the series look like

The platform Prometheus sees your workload under its host names: `namespace` is
`vcluster--<vcluster>`, and `pod` and `service` carry the `-x-<namespace>-x-vcluster--<vcluster>`
suffix. With no `jobLabel`, the `job` label is the host Service name for a ServiceMonitor and
`<host namespace>/<host monitor name>` for a PodMonitor. To find your series, filter on
`namespace="vcluster--<vcluster>"` and then on `service` or `pod`. [Monitoring](../monitoring/README.md)
shows where to query and how to build dashboards.

## Examples

| File | What it shows |
|---|---|
| [`deployment.yaml`](deployment.yaml) | An application serving metrics on a container port named `metrics` |
| [`service.yaml`](service.yaml) | The Service in front of it, with a port named `metrics` and the label `app: my-app` |
| [`serviceMonitor.yaml`](serviceMonitor.yaml) | A ServiceMonitor that scrapes the Service every 30 seconds |
| [`serviceMonitor-authorization.yaml`](serviceMonitor-authorization.yaml) | The same, for an endpoint that needs a bearer token from a Secret |
| [`podMonitor.yaml`](podMonitor.yaml) | A PodMonitor that scrapes the pods directly, without the Service |

The manifests set no namespace. Apply them to a namespace of your own with `-n`: platform policy
forbids the vcluster's `default` namespace, and [Your vcluster](../vcluster/README.md) shows how
to create one. Use `serviceMonitor.yaml` or `podMonitor.yaml`, not both: together they scrape
every pod twice, under two `job` values. The two ServiceMonitor files share the name `my-app`, so
apply one of them.

```bash
kubectl apply -n my-namespace -f deployment.yaml -f service.yaml -f serviceMonitor.yaml
```

`serviceMonitor-authorization.yaml` reads the token from a Secret named `my-app-metrics-token`
with the key `token`. Create it in the same namespace, from Vault as in [Secrets](../secrets/README.md)
or with `kubectl create secret generic my-app-metrics-token -n my-namespace --from-file=token=<file>`.

Monitors for operator-managed workloads work the same way and need the same switch. For
PostgreSQL, [PostgreSQL with CloudNativePG](../../operators/cloudnativepg/README.md) has PodMonitors
for the instances and PgBouncer.

## Mistakes that leave a target unscraped or noisy

| Mistake | Result |
|---|---|
| A vcluster without the Prometheus switch | `kubectl apply` fails with `no matches for kind "ServiceMonitor"`. Ask the platform team |
| `release: sdf-k8s01`, or any other label, on the monitor to get it selected | Not needed: the platform adds the label to the host copy. Harmless, but not what makes the monitor work |
| A `selector` on the `release` label of your Services or pods | No target. Host copies carry `release` under a rewritten key. Select on another label |
| `port: 8080` or another number | The manifest is rejected: `port` is a string naming a port. Name the port in the Service or pod spec and use the name |
| A port name that exists on the container but not on the Service (ServiceMonitor) | No target. A ServiceMonitor reads the Service's port names; name the Service port too |
| `namespaceSelector` to scrape another namespace, or `any: true` | Ignored. The platform sets the selector to your vcluster's host namespace, which already holds all your namespaces |
| The same `app` label value in two namespaces, for example `dev` and `prod` | Both are scraped by one monitor, and their series differ only by `pod` or `service`. Use a distinct label value per deployment |
| `jobLabel`, `targetLabels` or `podTargetLabels` on a ServiceMonitor, `jobLabel` on a PodMonitor | No effect. `job` stays the host Service name (ServiceMonitor) or `<host namespace>/<host monitor name>` (PodMonitor) |
| `basicAuth`, `bearerTokenSecret`, `oauth2` or `tlsConfig.keySecret` | The Secret is not copied to the host, so the credentials never reach Prometheus. Use `authorization.credentials` |
| A monitor and `prometheus.io/scrape` annotations on the same pods or Service | Every series is scraped twice, under different `job` values. Use one of the two |
| High-cardinality labels (user IDs, request paths, pod-template hashes) | Millions of series on the one shared Prometheus. Nothing stops it, so every tenant pays for it |
| A `PrometheusRule` in your vcluster | The platform Prometheus never evaluates it: alerting rules are not synced. See [Monitoring](../monitoring/README.md#alerting) for alerting |

Pods that have succeeded or failed are dropped from the targets, so a Job pod that finishes within
one interval may never be scraped. Export such metrics from a long-lived pod.

## Checking

The monitor has no `status` in your vcluster, published or not. Check the pieces it depends on,
then the target in Prometheus.

```bash
# The kinds exist only with the Prometheus switch.
kubectl api-resources --api-group=monitoring.coreos.com

# The Service has a port with the name the monitor uses, and endpoints behind it.
kubectl get svc my-app -n my-namespace -o jsonpath='{.spec.ports[*].name}{"\n"}'
kubectl get endpointslices -n my-namespace -l kubernetes.io/service-name=my-app

# The pods expose the metrics themselves.
kubectl run -n my-namespace curl --rm -it --restart=Never --image=curlimages/curl:8.13.0 -- \
  -s http://my-app.my-namespace.svc.cluster.local:8080/metrics | head
```

Then open the platform Prometheus, Status, Target health (see [Monitoring](../monitoring/README.md)
for the address) and search for `vcluster--<vcluster>`: your targets appear under a scrape pool
named after the host copy of the monitor. A target in state `DOWN` shows the scrape error, for
example a connection refused on the wrong port. A monitor with no scrape pool at all usually has a
`selector` that matches no Service or pod: compare its `matchLabels` with the labels of the
Service (`kubectl get svc -n my-namespace --show-labels`) or the pods.

Upstream reference: [ServiceMonitor](https://prometheus-operator.dev/docs/api-reference/api/#monitoring.coreos.com/v1.ServiceMonitor)
and [PodMonitor](https://prometheus-operator.dev/docs/api-reference/api/#monitoring.coreos.com/v1.PodMonitor)
in the Prometheus Operator API reference.
