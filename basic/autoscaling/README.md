# Resource metrics and autoscaling (metrics-server and HorizontalPodAutoscaler)

`kubectl top` shows the CPU and memory your pods use now, and a HorizontalPodAutoscaler (HPA)
adds and removes replicas of a Deployment or StatefulSet to keep that use near a target. Both read
the same resource metrics, which the platform's metrics-server collects on the host cluster and
your vcluster passes through. Use an HPA for stateless services whose load varies; it needs a
request, on every container, for the resource it scales on, which
[Requests and limits](../resources/README.md) covers.

Resource metrics are on in every vcluster. There is no switch to ask for. Only CPU and memory are
available: the platform registers no custom or external metrics API (`custom.metrics.k8s.io`,
`external.metrics.k8s.io`), so an HPA has no request rates, queue lengths or Prometheus queries to
scale on.

## How metrics reach your vcluster

1. The host cluster's metrics-server reads CPU and memory use from every node's kubelet, every
   15 seconds, for every pod on the host, including yours.
2. Your vcluster registers the `metrics.k8s.io` API and forwards each request to the host's
   metrics-server. The vcluster runs no metrics-server of its own, so every vcluster gets the same
   data and the same freshness.
3. On the way back, the vcluster keeps only the pods that belong to it and gives them back their
   names and namespaces in your vcluster. For nodes it returns only the nodes your vcluster sees.
4. The HPA controller in your vcluster's own controller-manager reads these metrics and sets the
   replica count of your Deployment or StatefulSet. HPAs never reach the host cluster: the host
   only ever sees the pods they create.

Because the vcluster reuses the host's metrics-server, you do not install or run one yourself, and
nothing in your vcluster needs to be kept up to date for `kubectl top` and HPAs to work.

## kubectl top

```bash
# CPU and memory use of each pod, now. Add --containers for one line per container.
kubectl top pods -n my-namespace
kubectl top pods -n my-namespace --containers

# The nodes your pods run on, with their whole use.
kubectl top nodes
```

What the numbers mean:

| Command | Shows | Notes |
|---|---|---|
| `kubectl top pods` | CPU in millicores and memory in use, per pod | Compare with the pod's requests. A pod above its memory request is an eviction candidate when the node runs short |
| `kubectl top pods --containers` | The same, per container | Finds the container that uses the memory in a pod with sidecars |
| `kubectl top nodes` | CPU and memory in use on each node, and the percentage of what the node can allocate to pods | The nodes are shared: the figures include every tenant's pods and the platform's, not only yours. Your vcluster lists only the nodes that run your pods |
| `kubectl top pods --sort-by=cpu` or `--sort-by=memory` | The same, sorted | Finds the pod to size first |

A new pod has no metrics until metrics-server has collected it, which it does every 15 seconds.
Until then `kubectl top pods` leaves the pod out of its list, and answers
`metrics not available yet` when none of the pods it selects has metrics. Try again.

## How an HPA scales

Every 60 seconds the HPA controller reads the metric for the pods of its target and computes:

```
desiredReplicas = ceil(currentReplicas * currentMetricValue / targetValue)
```

The Kubernetes documentation gives 15 seconds, the upstream default; vcluster starts its
controller-manager with a 60-second period, and the platform keeps vcluster's setting. A new HPA is first evaluated up to 60 seconds after you create it.

For a `Utilization` target, `currentMetricValue` is the pods' CPU use divided by the sum of their
CPU requests, as a percentage. This is why requests are required: without a CPU request there is
nothing to divide by, the controller reports the metric as `<unknown>`, and the HPA does nothing.
The same holds for memory `Utilization` and memory requests. A pod whose containers have neither
requests nor limits is also `BestEffort` and is the first to be evicted on a busy node: see
[Requests and limits](../resources/README.md).

When the current value is within 10% of the target, the controller changes nothing, so small
variations do not move the replicas. Then it applies the HPA's `behavior`, by default:

- Scale up: at once, by at most 4 replicas or double the current count, whichever is more, each
  time the controller runs.
- Scale down: only when the lower load has lasted 5 minutes (the stabilization window), then as
  many replicas as the metric allows.

For CPU, pods that are not yet `Ready` are left out of the average, so a new replica's start-up
CPU does not trigger another scale-up. Pods without a metric yet are counted as if they used
nothing when scaling up and exactly the target when scaling down, which dampens both.

## HPA settings

| Field | Value in the examples | What it is for |
|---|---|---|
| `scaleTargetRef` | `apps/v1` `Deployment` `my-app` | The object whose `replicas` the HPA sets. Also works for a StatefulSet |
| `minReplicas` | `2` | The HPA never goes below this. Use 2 or more for a service that must stay up through a node drain or failure: see [Disruptions](../scheduling/disruptions/README.md) |
| `maxReplicas` | `10` | The ceiling. Each replica reserves its requests on a node, so size it to what your nodes can take |
| `metrics[].type` | `Resource` or `ContainerResource` | `Resource` averages over the whole pod; `ContainerResource` looks at one named container, so a sidecar does not count |
| `resource.name` | `cpu` or `memory` | The only metrics available on this platform |
| `target.type: Utilization` | `averageUtilization: 70` | Percent of the pods' requests. Requires requests on every container the metric counts |
| `target.type: AverageValue` | `averageValue: 48Mi` | An absolute amount per pod. Works without requests, but set them anyway |
| `behavior.scaleDown.stabilizationWindowSeconds` | `600` | How long the lower load must last before replicas are removed. Longer keeps a short dip from taking pods away |
| `behavior.scaleDown.policies` | 1 pod per 60 seconds | Limits how fast replicas are removed |

CPU is the usual metric: it falls when load falls, so the HPA scales both ways. Memory rarely
falls when load does, so a memory HPA mainly adds replicas and seldom removes them; use it only for
applications whose memory tracks their load.

Set `minReplicas` so that the pods together can carry the normal load, and the CPU target below
100% so that the pods have headroom while new replicas start.

## Examples

| File | What it shows |
|---|---|
| [`deployment.yaml`](deployment.yaml) | A web server with CPU and memory requests and limits, and no `replicas` field |
| [`service.yaml`](service.yaml) | The Service in front of it, used by the load generator |
| [`hpa-cpu.yaml`](hpa-cpu.yaml) | 2 to 10 replicas on 70% CPU utilization, with a slow scale-down |
| [`hpa-memory.yaml`](hpa-memory.yaml) | 2 to 10 replicas on one container's average memory. An alternative to `hpa-cpu.yaml`, not an addition |
| [`load-generator.yaml`](load-generator.yaml) | A Job that sends requests for 5 minutes, to watch the HPA act |

The manifests set no namespace. Apply them to a namespace of your own with `-n`: platform policy
forbids the vcluster's `default` namespace, and [Your vcluster](../vcluster/README.md) shows how
to create one. The two HPAs have the same name and the same target: apply one of them.

## Mistakes that keep an HPA from scaling

| Mistake | Result |
|---|---|
| No CPU request on a container, with a CPU `Utilization` target | `kubectl get hpa` shows `cpu: <unknown>/70%`, the HPA never scales, and its events say `missing request for cpu in container ...`. Add requests to every container, sidecars included |
| `spec.replicas` in the Deployment manifest, or in a kustomization or GitOps tool | Every `kubectl apply` or sync sets the replicas back, and the HPA sets them again. Remove the field and let the HPA own the count. Removing it from a Deployment that already runs drops the replicas to 1 once; to avoid that, first remove it from the recorded state with `kubectl apply edit-last-applied deployment/my-app`, then from the manifest |
| `kubectl scale` on an HPA-managed Deployment | The HPA starts to set the count back the next time it runs, within a minute, at the pace its `behavior` allows. Change `minReplicas` or `maxReplicas` instead |
| A `Pods`, `Object` or `External` metric, for example requests per second from Prometheus | The platform has no metrics adapter, so the metric is `<unknown>` and the HPA never scales. Use CPU or memory |
| A memory target on an application that keeps memory once allocated | The HPA scales up and never scales down. Use CPU, or an application that frees memory with load |
| `maxReplicas` larger than the nodes can hold | Replicas that fit on no node stay `Pending`, and the `Pending` pods add nothing to the load the others carry |
| `minReplicas: 1` for a service that must stay up | During a host node drain or failure the one replica is gone until it is rescheduled. Use 2 or more |
| Two HPAs for one Deployment, for example one on CPU and one on memory | Neither scales: both report `AmbiguousSelector` (`... are controlled by multiple HPAs`). Put both metrics in one HPA: it scales to the larger of the two results |
| A CPU limit equal to the request, with a high utilization target | The container is throttled at 100% of its request, so utilization cannot rise far above the target and the HPA adds replicas in small steps while the pods are throttled. Set the limit above the request |

## Testing

```bash
kubectl apply -n my-namespace -f deployment.yaml -f service.yaml -f hpa-cpu.yaml

# TARGETS shows cpu: <unknown>/70% for the first minute or two, then the actual percentage.
kubectl get hpa my-app -n my-namespace

# Start the load and watch the replicas grow; the load stops after 5 minutes.
kubectl apply -n my-namespace -f load-generator.yaml
kubectl get hpa my-app -n my-namespace --watch

# What the controller decided and why, in the Events and Conditions at the end.
kubectl describe hpa my-app -n my-namespace

# The use the HPA is working from.
kubectl top pods -n my-namespace -l app=my-app

# Keep watching: scale-down starts about 10 minutes after the load ends (the stabilization
# window in hpa-cpu.yaml), then removes one replica a minute.
kubectl get hpa my-app -n my-namespace --watch

# Clean up.
kubectl delete -n my-namespace -f load-generator.yaml -f hpa-cpu.yaml -f service.yaml -f deployment.yaml
```

In `kubectl describe hpa`, the condition `ScalingActive: True` with reason `ValidMetricFound` means
the controller is reading the metric. `ScalingActive: False` with `FailedGetResourceMetric` means
it cannot: the events below it say whether a request is missing or the metrics are not there yet.
The finished load-generator pod is deleted by the platform 10 to 25 minutes after it is created:
see [Jobs and CronJobs](../jobs/README.md).

Upstream reference:
[Horizontal Pod Autoscaling](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)
and the [metrics-server](https://github.com/kubernetes-sigs/metrics-server) project.
