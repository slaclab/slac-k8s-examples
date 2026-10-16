# Requests, limits, QoS and ephemeral storage (host scheduler and kubelet)

Requests and limits tell Kubernetes how much CPU, memory and node disk (ephemeral storage) a
container needs and how much it may use. Requests reserve capacity on a node; limits cap use. On
the S3DF Kubernetes platform they are your pods' only protection on shared nodes: the platform
sets no quota and no defaults, every tenant pod runs at priority 0, below the platform's own
services, and when a node runs short, the kubelet evicts the pods that use more than they
requested first. Set requests on every container, and limits on memory and ephemeral storage.
Read this guide before you size a workload, and when pods are `OOMKilled`, evicted or stuck
`Pending`.

The commands below use the namespace `my-namespace`. Create your own namespace as shown in
[Your vcluster](../vcluster/README.md); platform policy forbids the `default` namespace.

## How the platform uses your numbers

Write the resources in the manifests you apply to your vcluster. The platform does the rest:

1. The vcluster syncs the pod to the host cluster with your containers' requests and limits
   unchanged. Your vcluster has no ResourceQuota or LimitRange, and no host policy adds defaults,
   rejects a pod without requests or limits, or reports it.
2. The host scheduler places the pod on a node whose unrequested CPU, memory and ephemeral storage
   cover the pod's requests. It ignores actual use and limits, so a node can run short
   while every pod is within its limits.
3. On the node, the limits apply: a container above its memory limit is killed and restarted, a
   container at its CPU limit is slowed down, and a pod above its ephemeral-storage limit is
   evicted.
4. When a node runs short of memory or disk space, the kubelet evicts pods. It takes the pods that
   use more than they requested first, lowest priority first, then those furthest above their
   requests.
5. If memory runs out faster than the kubelet acts, the kernel's OOM killer stops containers
   instead: `BestEffort` first, `Guaranteed` last.

Every tenant pod runs at priority 0 on the host, whatever `priorityClassName` it has in your
vcluster: PriorityClasses are not synced. Platform services and vcluster control planes run in
higher priority classes, so that the services every vcluster depends on keep running when a node
is short. Among the pods above their requests, yours are evicted before the platform's, and the
scheduler can preempt your pods to make room for theirs. Staying within your requests is therefore the only
protection against eviction that you control.
[Disruptions](../scheduling/disruptions/README.md) covers preemption and the other ways pods are
stopped.

Most nodes are shared by many vclusters, so what one pod takes beyond its request comes from its
neighbours. Requests you do not use are capacity that no other pod can be scheduled onto: size
them to what the container uses, not to what it might ever use.

## QoS classes

Kubernetes gives each pod a QoS class from the CPU and memory settings of all its containers,
init containers included. Ephemeral storage and huge pages do not count.

| Class | When | What it means here |
|---|---|---|
| `Guaranteed` | Every container has CPU and memory requests equal to its limits | It cannot use more memory than it requested, so under memory pressure it goes only after the pods above their requests. Use it for services that must keep running |
| `Burstable` | At least one container has a CPU or memory request or limit, and the pod is not `Guaranteed` | It may use idle CPU and memory above its requests, but while it is above them it is an eviction candidate |
| `BestEffort` | No container has a CPU or memory request or limit | It is always above its requests (zero), so it is always an eviction candidate, and it is the first OOM victim. The scheduler reserves nothing for it |

On the host, the vcluster adds an init container, `vcluster-rewrite-hosts`, to each StatefulSet
pod, so that the pod's `/etc/hosts` holds the fully qualified name the vcluster expects. It
requests 30m CPU and 64Mi memory, with limits equal to the requests, so a `Guaranteed` pod stays
`Guaranteed`.

## What to set

| Field | Value | What it is for |
|---|---|---|
| `requests.cpu` | What the container uses most of the time, for example `100m` (0.1 CPU) | Reserved on the node. Under contention, CPU is shared in proportion to requests. HorizontalPodAutoscaler CPU targets are a percentage of it |
| `requests.memory` | Normal use plus headroom | Reserved on the node. Staying under it keeps the pod off the front of the eviction queue |
| `limits.memory` | Peak use | Above it the kernel kills the container (`OOMKilled`, exit code 137), and it restarts |
| `limits.cpu` | Optional; equal to `requests.cpu` for `Guaranteed` | Caps the container. At the limit the kernel throttles it, even when the node has idle CPUs |
| `requests.ephemeral-storage` | Expected size of the logs, the files written outside volumes and the disk `emptyDir` volumes | Reserved on the node's disk |
| `limits.ephemeral-storage` | The most the container may write there | Above it the kubelet evicts the pod |

Set at least CPU and memory requests and a memory limit on every container, init containers and
sidecars included. If you set only limits, Kubernetes copies them into the requests, so the pod
reserves its whole limit even when idle.

## Ephemeral storage

Ephemeral storage is the disk of the node the pod runs on, shared by every pod on that node. It
holds:

- the files a container writes outside its volumes (the container's writable layer),
- the container's logs,
- `emptyDir` volumes, except memory-backed ones.

Volumes from a PersistentVolumeClaim (Weka, S3DF filesystems, node-local ZFS) are not ephemeral
storage. For large scratch space, or scratch data that must outlive the pod, use a claim;
[Storage](../storage/README.md) helps you choose the class.

Writes do not fail at these limits. The kubelet measures use periodically and evicts the pod once
it is over:

| Limit | What counts | Above it |
|---|---|---|
| `limits.ephemeral-storage` of a container | That container's logs and writable layer | The kubelet evicts the pod |
| The sum of the containers' `limits.ephemeral-storage` | All logs and writable layers, plus the pod's disk `emptyDir` volumes | The kubelet evicts the pod |
| `emptyDir.sizeLimit` | That volume | The kubelet evicts the pod |

When a node runs short of disk space, the kubelet evicts pods on it, starting with the pods above
their ephemeral-storage requests. One pod that writes without a limit can fill the disk
and get its neighbours evicted. Set ephemeral-storage requests and limits on containers that write
files, and a `sizeLimit` on every `emptyDir`.

The platform Prometheus records each pod's ephemeral-storage use (`ephemeral_storage_pod_usage`)
and that use as a percentage of each container's ephemeral-storage limit
(`ephemeral_storage_container_limit_percentage`; for a container without a limit, the node's free
space instead). Your pods appear there under their host names;
[Monitoring](../monitoring/README.md) explains where to query them.

## Memory-backed emptyDir

An `emptyDir` with `medium: Memory` is a tmpfs in the node's memory. It is fast, and it is memory:

- Its files count as memory used by the container that writes them, against that container's
  memory limit. They stay in memory until they are deleted, even if the container restarts.
- It holds at most the smaller of its `sizeLimit` and the sum of the memory limits of all the
  pod's containers; without either, as much as the node's allocatable memory. A write beyond that
  fails with `No space left on device`.

Set `sizeLimit`, and size the writing container's memory request and limit for its own use plus
the full `sizeLimit`. Otherwise the files and the process together reach the limit, and the
container is `OOMKilled` before the volume is full.

## Huge pages

A pod gets huge pages only if it sets a `hugepages-<size>` limit; Kubernetes
[describes how](https://kubernetes.io/docs/tasks/manage-hugepages/scheduling-hugepages/). Your
vcluster shows only the nodes your pods run on, so it cannot tell you which nodes offer them. Ask
the platform team (s3df-help) before you build on huge pages.

GPUs are also set in `limits`, as the extended resource `nvidia.com/gpu`; see
[GPU workloads](../gpu/README.md).

## Examples

| File | What it shows |
|---|---|
| [`deployment-burstable.yaml`](deployment-burstable.yaml) | Requests sized to normal use, memory and ephemeral-storage limits, no CPU limit: `Burstable` |
| [`deployment-guaranteed.yaml`](deployment-guaranteed.yaml) | CPU and memory requests equal to the limits: `Guaranteed` |
| [`pod-emptydir-disk.yaml`](pod-emptydir-disk.yaml) | Scratch space on the node's disk: an `emptyDir` with `sizeLimit`, and ephemeral-storage requests and limits |
| [`pod-emptydir-memory.yaml`](pod-emptydir-memory.yaml) | Scratch space in memory: a `Memory` `emptyDir` with `sizeLimit`, inside the memory limit |

The manifests set no namespace; apply them with `-n`.

```bash
kubectl apply -n my-namespace -f deployment-burstable.yaml -f deployment-guaranteed.yaml
kubectl get pods -n my-namespace -o custom-columns=NAME:.metadata.name,QOS:.status.qosClass

kubectl apply -n my-namespace -f pod-emptydir-disk.yaml
kubectl logs -n my-namespace my-app-scratch      # the size of /scratch after writing 100 MiB

kubectl delete -n my-namespace --ignore-not-found \
  -f deployment-burstable.yaml -f deployment-guaranteed.yaml -f pod-emptydir-disk.yaml
```

The pod examples finish after an hour. The platform deletes finished pods at its next
cleanup, within 15 minutes; see [Jobs and CronJobs](../jobs/README.md).

## Mistakes that get pods killed, evicted or stuck

| Mistake | Result |
|---|---|
| No requests or limits | `BestEffort`: always an eviction candidate when the node is short, and the first OOM victim. The scheduler reserves nothing for it, so it can land on a node that is already busy |
| Limits without requests | Kubernetes sets the requests equal to the limits. The pod reserves its whole limit even when idle, and may fit on no node |
| Memory limit below peak use | The container is `OOMKilled` (exit code 137) and restarts; if that repeats, it goes into `CrashLoopBackOff` |
| Memory request far below normal use | The pod runs, but it is above its request most of the time, so it is among the first evicted when the node is short |
| A CPU limit on a latency-sensitive service | The kernel throttles the container whenever it reaches the limit, even with idle CPUs on the node: slow responses and probe timeouts |
| Requests larger than any node can offer | The pod stays `Pending` with a `FailedScheduling` event such as `Insufficient cpu` or `Insufficient memory` |
| Letting a program choose its worker or thread count from the CPU count | Many programs count all the node's CPUs, not your request or limit, and start more workers than the memory limit can hold. Set the count explicitly |
| An `emptyDir` or a writable layer that grows without a limit | It fills the node's disk. The kubelet then evicts pods on that node, starting with the pods above their ephemeral-storage requests |
| A `Memory` `emptyDir` without `sizeLimit`, or a memory limit with no room for it | Its files count as memory: the container is `OOMKilled` when the files and the process together reach the limit |
| A PriorityClass or `priorityClassName` in the vcluster | No effect: every tenant pod runs at priority 0 on the host |

An evicted pod stays in phase `Failed` with reason `Evicted`, but not for long: every 15 minutes
the platform deletes failed pods created more than 10 minutes earlier. Read its status and events
soon. A Deployment or StatefulSet replaces an evicted pod; a bare pod is gone.

## Checking

```bash
# The QoS class of each pod.
kubectl get pods -n my-namespace -o custom-columns=NAME:.metadata.name,QOS:.status.qosClass

# CPU and memory use now, per container, to compare with the requests.
kubectl top pods -n my-namespace --containers

# How each container last stopped: OOMKilled (exit code 137) means it reached its memory limit.
kubectl get pod <pod> -n my-namespace \
  -o jsonpath='{range .status.containerStatuses[*]}{.name}{"\t"}{.lastState.terminated.reason}{"\t"}{.lastState.terminated.exitCode}{"\n"}{end}'

# Evictions, with the resource that ran short, and pods that fit on no node.
kubectl get events -n my-namespace --field-selector reason=Evicted
kubectl get events -n my-namespace --field-selector reason=FailedScheduling

# How full an emptyDir is.
kubectl exec -n my-namespace my-app-scratch -- du -sh /scratch

# What a node offers: Capacity and Allocatable, including ephemeral-storage.
kubectl get pod <pod> -n my-namespace -o wide    # the NODE column
kubectl describe node <node>
```

Your vcluster shows only the nodes your pods run on, and the "Allocated resources" section of
`kubectl describe node` counts only your own pods. [Resource metrics](../autoscaling/README.md)
covers `kubectl top` and autoscaling on requests.

Upstream reference:
[Resource management for pods and containers](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/),
[Pod QoS classes](https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/),
[Node-pressure eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/).
