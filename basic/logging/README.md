# Container logs and Kubernetes events (Loki and k8s-event-logger)

The platform collects what every container writes to standard output and standard error, and
stores it in Loki, a log store you query from Grafana. You install no log agent and no sidecar.
`kubectl logs` and `kubectl get events` work inside your vcluster as in any cluster, but only for a
short time: the host cluster deletes finished pods within minutes, and events last about an hour.
Loki, and a log of host events kept in Loki, are the record that remains. Logging needs no
platform switch.

## How logs are collected

1. Your pods run on the host cluster, in `vcluster--<name>`, under their host names
   ([Names on the host](../vcluster/README.md#names-on-the-host)).
2. The container runtime on each node writes each container's standard output and standard error
   to a log file on the node.
3. A promtail agent on every node reads those files and sends each line to Loki, with the labels
   below.

Only standard output and standard error are collected. A file your application writes inside the
container is not read by anything, and is lost with the container.

## Labels of your log streams

| Label | Value | Notes |
|---|---|---|
| `namespace` | `vcluster--<name>` | Your host namespace, the same for every namespace inside your vcluster |
| `pod` | `<pod>-x-<namespace>-x-vcluster--<name>` | The host name. A name longer than 63 characters is cut to its first 52 characters, a dash and a 10-character hash |
| `container` | The container name | Unchanged |
| `app` | The pod label `app.kubernetes.io/name`, else `app` | Without either label: `vcluster--<name>` for a pod that a Deployment, StatefulSet or Job creates, the host pod name for a bare pod |
| `instance` | The pod label `app.kubernetes.io/instance`, else `instance` | Absent if neither is set |
| `component` | The pod label `app.kubernetes.io/component`, else `component` | Absent if neither is set |
| `job` | `<namespace>/<app>` | Built from the two labels above |
| `node_name` | The host node | |

The namespace inside your vcluster is not a label of its own: it appears only in the host pod
name. Set `app.kubernetes.io/name` (and `instance` and `component` where they help) on your pod
templates, so your streams are easy to tell apart.

## Retention and access

- The platform's Loki sets no retention period, so it does not delete logs by age. That is the
  current configuration, not a promise: keep logs you are required to keep in storage of your
  own.
- Treat your logs as readable by others: never log passwords, tokens or personal data.
- On some nodes, the platform also forwards the logs of containers with certain names, such as
  `nginx`, `gateway` and `registry`, to SLAC's Splunk for security operations.

## Reading logs

While the pod exists, read its logs from your vcluster. The vcluster fetches them from the host
node, so they are the same lines Loki has:

```sh
kubectl logs -n my-namespace deployment/my-app
kubectl logs -n my-namespace -l app.kubernetes.io/name=my-app --prefix --tail=50
kubectl logs -n my-namespace my-app-7d4b9c6f8-abcde --previous   # the container before its last restart
```

After the pod is gone, read its logs from Loki with LogQL. The platform Grafana
(`https://grafana.slac.stanford.edu`, SLAC SSO) has the Logs Drilldown app for Loki installed.
Grafana gives a new user the Viewer role, and Grafana's Explore needs more than that: ask the
platform team (s3df-help) for access to Loki in Grafana. Example LogQL queries:

```logql
# All logs of one application.
{namespace="vcluster--my-vcluster", app="my-app"}

# One namespace of your vcluster, through the host pod name.
{namespace="vcluster--my-vcluster", pod=~".+-x-my-namespace-x-vcluster--my-vcluster"}

# JSON log lines, filtered on a field.
{namespace="vcluster--my-vcluster", app="my-app"} | json | level="error"

# Lines containing a string.
{namespace="vcluster--my-vcluster", container="my-app"} |= "not found"
```

A pod name cut to 63 characters loses the end of its host name, so the second query misses those
pods; filter on `app` or `container` instead.

## Events

Scheduling, image pulls, volume mounts, probes and container kills happen on the host. The
vcluster copies the host's events about your pods and other synced objects into your vcluster,
under your names, so `kubectl describe` and `kubectl get events` show them. Events made by your
vcluster's own controllers, such as Deployment scaling and Job completion, exist only in your
vcluster.

Your vcluster keeps events for about an hour, the Kubernetes default, which the platform does
not change. To keep a longer history, the platform runs k8s-event-logger, which writes each new event on the host as a
JSON line to its own standard output, so Loki stores it. Each event is logged when it is first
recorded; later repeats only raise its `count` on the host and are not logged again, and a
restart of the logger logs the current events a second time. In this
history the events carry host names, and events from your vcluster's own controllers are absent.

```logql
{namespace="monitoring-system", container="k8s-event-logger"}
  |= "vcluster--my-vcluster"
  | json
  | involvedObject_namespace="vcluster--my-vcluster"
```

Add `| reason="FailedMount"` or `|= "my-app"` to narrow it down.

## Writing logs

- Write to standard output or standard error, never to a file in the container.
- Write one record per line. Each line is a separate entry in Loki, so a multi-line stack trace
  arrives as many unrelated entries. Log it as one JSON line instead.
- Prefer JSON with fixed field names (`time`, `level`, `msg`, and request or job IDs), so `| json`
  can filter on them.
- Log in proportion: Loki is shared by every vcluster, and a container's log files on the node
  count towards its ephemeral storage
  ([Requests, limits, QoS and ephemeral storage](../resources/README.md)).
- For a container that fails, set `terminationMessagePolicy: FallbackToLogsOnError`. Kubernetes
  then copies the last lines of its log (at most 80 lines or 2048 bytes) into the container
  status, where `kubectl describe pod` shows them next to the exit code.

A Job's pods are deleted within minutes of finishing, with their logs and status. To keep the log
of each attempt, see [Jobs and CronJobs](../jobs/README.md). For metrics, see
[Monitoring](../monitoring/README.md).

## Examples

| File | What it shows |
|---|---|
| [`deployment-json-logs.yaml`](deployment-json-logs.yaml) | A Deployment that writes one JSON record per line to standard output, with the labels that set `app`, `instance` and `component` in Loki |
| [`pod-termination-message.yaml`](pod-termination-message.yaml) | A pod that fails, with its last log lines kept as the termination message |

## Mistakes that lose logs

| Mistake | Result |
|---|---|
| Logging to a file inside the container | Never collected; lost when the container restarts, and it fills the container's ephemeral storage |
| Relying on `kubectl logs` or `kubectl describe pod` for a finished pod | The host deletes finished pods 10 to 25 minutes after their creation, or within 15 minutes of finishing for longer runs. Read the logs in Loki |
| Relying on `kubectl get events` after an hour | The event is gone from your vcluster. Host events are in the k8s-event-logger history in Loki |
| Pod templates without `app.kubernetes.io/name` or `app` | Every controller-created pod of your vcluster gets the Loki label `app="vcluster--<name>"` |
| Searching Loki for your vcluster's pod or namespace names | Loki has the host names, in namespace `vcluster--<name>` |
| Multi-line log records | Each line is a separate entry, out of context and hard to search |
| Logging secrets or personal data | Readable by everyone with access to Loki |

## Checking

```sh
kubectl apply -n my-namespace -f deployment-json-logs.yaml
kubectl logs -n my-namespace deployment/my-app --tail=3

kubectl apply -n my-namespace -f pod-termination-message.yaml
kubectl get pod -n my-namespace my-app-failing   # STATUS Error once it has run
kubectl get pod -n my-namespace my-app-failing \
  -o jsonpath='{.status.containerStatuses[0].state.terminated.message}'
kubectl describe pod -n my-namespace my-app-failing   # Last State, Exit Code 3, Message

# Recent events, newest last.
kubectl get events -n my-namespace --sort-by=.lastTimestamp

kubectl delete -n my-namespace -f deployment-json-logs.yaml -f pod-termination-message.yaml
```

Then look for `{namespace="vcluster--my-vcluster", app="my-app"}` in Grafana: the lines of both
examples are there, and stay after the pods are deleted.

Upstream reference: [Logging architecture](https://kubernetes.io/docs/concepts/cluster-administration/logging/)
and [termination messages](https://kubernetes.io/docs/tasks/debug/debug-application/determine-reason-pod-failure/)
in the Kubernetes documentation, and [LogQL](https://grafana.com/docs/loki/latest/query/) in the
Loki documentation.
