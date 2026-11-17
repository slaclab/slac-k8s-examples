# Node placement, taints and tolerations (host scheduler)

Your pods run on the nodes of the host cluster, and the host's scheduler places them.
General-purpose nodes take any pod. Other nodes are tainted for a dedicated use, such as GPUs or
Rubin embargo processing, and the platform adds the tolerations that let the right pods onto them.
Read this guide when a pod needs particular hardware, when replicas should spread over nodes, or
when a pod stays `Pending`.

Access to the Rubin embargo and RSP nodes, and pinning a whole vcluster to a node pool, are
per-vcluster settings that the platform team makes. Ask the platform team (s3df-help), and see
[Your vcluster](../vcluster/README.md#features-and-allowlists-the-platform-sets).

## How the host places a pod

Write Deployments, StatefulSets and Jobs without tolerations. The platform does the rest:

1. The vcluster syncs each pod to the host cluster, into the namespace `vcluster--<name>`. If the
   platform has pinned your vcluster to a node pool, the vcluster adds the pool's `nodeSelector`,
   and the pool's toleration if the pool is tainted, to every pod.
2. The host cluster (Kyverno) adds the tolerations a pod is entitled to: the GPU toleration when a
   container sets a `nvidia.com/gpu` limit, and the Rubin embargo or RSP toleration and
   `nodeSelector` when the pod carries the pool's annotation in a vcluster entitled to the pool.
3. The host scheduler places the pod. Your vcluster runs no scheduler of its own, so your
   `nodeSelector`, node affinity and tolerations reach the host scheduler as written. The real
   nodes decide: their labels, their taints, and whether your pods'
   [requests](../resources/README.md) fit.
4. The vcluster syncs the chosen node into your vcluster, and copies the host's events to your pod,
   including the scheduler's reason when it cannot place the pod.

## Node pools and their taints

| Nodes | Taint key (effect `NoSchedule`) | How a pod gets there |
|---|---|---|
| General-purpose | None | Any pod. Your workloads run here unless they need something else |
| GPU | `nvidia.com/gpu` | A `nvidia.com/gpu` limit on a container. See [GPU workloads](../gpu/README.md) |
| Rubin embargo | `edu.stanford.slac.sdf.project/usdf-embargo` | The pod annotation `edu.stanford.slac.sdf.project/usdf-embargo: "true"`, in an entitled vcluster |
| Rubin Science Platform (RSP) | `edu.stanford.slac.sdf.project/rsp` | The pod annotation `edu.stanford.slac.sdf.project/rsp: "true"`, in an entitled vcluster |
| Rubin Qserv | `edu.stanford.slac.sdf.project/qserv` | Only from a vcluster the platform has pinned to the pool |
| External networks (Multus) | `node-role.kubernetes.io/ext-load-balancer` | A toleration together with a node selector for the network, as in [Secondary networks with Multus](../../advanced/multus-secondary-networks/README.md) |
| vcluster etcd | `edu.stanford.slac.sdf.storage/vcluster-etcd` | None: reserved for the etcd of the vcluster control planes |
| Host control plane | `node-role.kubernetes.io/master` | None |

The taints keep general workloads off hardware that has a dedicated owner or role, and the
platform controls each way in, so you never write these tolerations yourself. For GPUs, the GPU
limit is the opt-in: the taint keeps pods that need no GPU off the scarce GPU nodes, and the host
tolerates it for every pod that asks for a GPU. For the Rubin pools, the host checks the
annotation against the vclusters entitled to the pool, which a toleration alone cannot do.

### GPU pods

Set `nvidia.com/gpu` in the `limits` of a container in `containers`. The host adds the toleration
`{key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}` unless the pod already tolerates that
key. An initContainer's GPU limit does not count. Write no GPU toleration, and no node selector
just to reach GPU nodes: the GPU limit already keeps the pod on them. To choose a GPU model, see
[GPU workloads](../gpu/README.md).

### Rubin embargo and RSP pods

In a vcluster entitled to the pool, put the annotation on the pod template, in
`spec.template.metadata.annotations`. The host matches pods only, so an annotation on the
Deployment's own metadata does nothing. The host then adds the pool's toleration and a
`nodeSelector` on the pool's label (`edu.stanford.slac.sdf.project/usdf-embargo: "true"` or
`edu.stanford.slac.sdf.project/rsp: "true"`), so the pod runs only on the pool. Pods without the
annotation run on general-purpose nodes, so only the pods that need the pool use it.

In any other vcluster, the host rejects a pod that carries the annotation. The pod stays `Pending`
in your vcluster, and `kubectl describe pod` shows a `SyncError` event with the host's message.

### A vcluster pinned to a pool

The platform can pin a whole vcluster to a node pool. That vcluster adds a `nodeSelector` on the
pool's label to every pod it syncs, and, for a tainted pool, the pool's toleration
(`enforceTolerations` in its configuration). The platform does this in the vcluster's own
configuration, instead of trusting each manifest to carry it. You add nothing, and your pods cannot
run anywhere else: a volume that the pool's nodes cannot mount leaves a pod `Pending`. Ask the
platform team which storage the pool has.

## Never tolerate every taint

```yaml
tolerations:
  - operator: Exists   # No key: this tolerates every taint. Never do this.
```

A toleration with `operator: Exists` and no `key` tolerates every taint. The pod can then land on
the host control plane, the vcluster etcd nodes or another project's pool. It also tolerates,
without a time limit, the `NoExecute` taints that move pods off a failed node:
`node.kubernetes.io/not-ready`, `node.kubernetes.io/unreachable`, and
`node.kubernetes.io/out-of-service`, which the platform adds to many of its nodes when they stop
responding. The pod then stays bound to the dead node instead of being replaced on a healthy one;
see [Disruptions](disruptions/README.md).

Write a toleration yourself only where a guide shows one, with its `key` and `effect`, as the
Multus guide does.

## Choosing nodes by hardware

Most workloads need no node selection. When one needs particular hardware, select on the hardware,
with a `nodeSelector` or node affinity on a Node Feature Discovery (NFD) label. Never select a
node by its name: a pod pinned to one node cannot run anywhere else while that node is drained or
down.

| Label | Value | What it means |
|---|---|---|
| `feature.node.kubernetes.io/pci-<vendor>.present` | `"true"` | The node has a network, InfiniBand, display or 3D controller from that PCI vendor, for example `pci-15b3.present` for Mellanox adapters |
| `feature.node.kubernetes.io/rdma.capable` | `"true"` | The node has an RDMA-capable network adapter |
| `feature.node.kubernetes.io/rdma.available` | `"true"` | The node has the RDMA kernel modules loaded |
| `feature.node.kubernetes.io/kernel-version.*`, `feature.node.kubernetes.io/system-os_release.*` | Version strings | The node's kernel and operating system release |

NFD sets a feature label only on nodes that have the feature. A label selects nodes; it does not
give the pod the device. NFD's CPU source is turned off on S3DF, so there are no
`feature.node.kubernetes.io/cpu-*` labels. For GPU models, see [GPU workloads](../gpu/README.md).

Three kinds of node label are not for your own selectors:

- **Storage labels** (`edu.stanford.slac.sdf.storage/...`). A volume places its pod itself: an
  S3DF filesystem claim carries the node affinity it needs
  ([S3DF filesystems](../storage/sdf-filesystem/README.md)), and a node-local volume ties its pod
  to the volume's node ([Node-local ZFS volumes](../storage/node-local-zfs/README.md)).
- **Pool labels** (`edu.stanford.slac.sdf.project/...`). Use the pool's way in, above.
- **Network labels** (`edu.stanford.slac.sdf.networking/...` and
  `edu.stanford.slac.sdf.k8s.networking.multus`). Use them only as
  [Secondary networks with Multus](../../advanced/multus-secondary-networks/README.md) shows.

## Spreading replicas

Spread replicas over nodes with `topologySpreadConstraints` on `kubernetes.io/hostname`, so that
one node failure or drain stops one replica, not all of them. Use
`whenUnsatisfiable: ScheduleAnyway`, unless a replica should rather stay `Pending` than share a
node. The vcluster limits the constraint's `labelSelector` to pods in the same namespace of your
vcluster, so other tenants' pods never count.

Spreading is your main protection here: PodDisruptionBudgets in your vcluster are not synced to
the host, so they do not hold off a host drain (see [Disruptions](disruptions/README.md)).

## What your vcluster shows

- `kubectl get nodes` lists only the nodes where your vcluster's pods run, not the whole cluster.
  It does not show which hardware exists elsewhere, and `kubectl describe node` counts only your
  own pods, so it does not show how full a node is.
- Those nodes show their real labels and taints. Changes you make to them in your vcluster are not
  synced back, so they change neither the host node nor where pods run. The platform keeps node
  changes from flowing back so that no vcluster can relabel or retaint the shared nodes.
- A DaemonSet in your vcluster runs only on these nodes.

## Priority classes

PriorityClasses are not synced between your vcluster and the host, and the vcluster clears
`priorityClassName` and `priority` on every pod it syncs, so on the host your pods run at priority
0. The platform gives higher priority classes to its own services and to every vcluster's control
plane, so that they keep running when nodes run short. A platform pod that does not fit on a node
can preempt your pods; tenant pods, all at the same priority, never preempt each other. Leave
`priorityClassName` unset: it does not raise a pod's priority on the host. See
[Disruptions](disruptions/README.md).

## Examples

| File | What it shows |
|---|---|
| [`deployment-spread.yaml`](deployment-spread.yaml) | Three replicas on general-purpose nodes, spread over nodes |
| [`deployment-node-affinity.yaml`](deployment-node-affinity.yaml) | A Deployment that runs only on nodes with an RDMA-capable adapter, selected by NFD label |
| [`deployment-rubin-embargo.yaml`](deployment-rubin-embargo.yaml) | The Rubin embargo annotation on the pod template, for vclusters entitled to the pool. For the RSP pool, use `edu.stanford.slac.sdf.project/rsp` instead |

The manifests set no namespace. Apply them to a namespace of your own with `-n`: platform policy
forbids the vcluster's `default` namespace, and [Your vcluster](../vcluster/README.md) shows how to
create one.

```bash
kubectl apply -n my-namespace -f deployment-spread.yaml
kubectl get pods -n my-namespace -l app=my-app -o wide   # NODE: a different node for each replica, where there is room
```

## Mistakes that strand a pod or put it on the wrong nodes

| Mistake | Result |
|---|---|
| A toleration with `operator: Exists` and no `key` | Tolerates every taint: the pod can land on reserved nodes, and is never moved off a failed node |
| A toleration for a pool's taint, written by hand | The pod can land on hardware reserved for the platform or another project. Use the pool's way in |
| The embargo or RSP annotation on the Deployment's `metadata`, not the pod template's | No toleration or nodeSelector: the pod runs on general-purpose nodes |
| An embargo or RSP annotation value other than `"true"` | Ignored: the pod runs on general-purpose nodes. (`true` without quotes is refused by `kubectl apply`: annotation values must be strings) |
| The embargo or RSP annotation in a vcluster not entitled to the pool | The host rejects the pod: it stays `Pending`, with a `SyncError` event |
| A GPU limit only on an initContainer | The host adds no GPU toleration, and the pod stays `Pending` |
| A `nodeSelector` or required affinity on `kubernetes.io/hostname` | The pod can run only on that node, and stays `Pending` while the node is drained or down |
| A `nodeSelector` or node affinity for storage | Not needed: the volume places the pod. A selector that matches no node with the storage leaves the pod `Pending` |
| A `feature.node.kubernetes.io/cpu-*` label in a selector | No node carries one, so the pod stays `Pending` |
| `kubectl label node` or `kubectl taint node` in your vcluster | No effect on the host node or on where pods run |
| A PriorityClass and `priorityClassName` in your vcluster | The pod's priority on the host does not rise |
| Reading `kubectl get nodes` as the cluster's capacity | It lists only the nodes your pods already run on |

## Checking

```bash
# Where each pod runs. NODE is <none> while a pod is Pending.
kubectl get pods -n my-namespace -l app=my-app -o wide

# Why a pod is Pending: the scheduler's event names untolerated taints, unmatched selectors
# and insufficient resources. A SyncError event means the host rejected the pod.
POD=$(kubectl get pods -n my-namespace -l app=my-app -o name | head -n 1)
kubectl describe -n my-namespace "$POD" | sed -n '/^Events:/,$p'

# The NFD labels of the node the pod runs on.
NODE=$(kubectl get -n my-namespace "$POD" -o jsonpath='{.spec.nodeName}')
kubectl get node "$NODE" \
  -o go-template='{{range $k, $v := .metadata.labels}}{{$k}}={{$v}}{{"\n"}}{{end}}' \
  | grep feature.node.kubernetes.io

# The nodes your vcluster sees, with their taints.
kubectl get nodes -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints[*].key'
```

An embargo or RSP pod must run on a node with the pool's label:

```bash
POD=$(kubectl get pods -n my-namespace -l app=my-app-embargo -o name | head -n 1)
NODE=$(kubectl get -n my-namespace "$POD" -o jsonpath='{.spec.nodeName}')
kubectl get node "$NODE" \
  -L edu.stanford.slac.sdf.project/usdf-embargo,edu.stanford.slac.sdf.project/rsp
```

If the pod runs on a node without the label, or a GPU pod stays `Pending` with an untolerated
`nvidia.com/gpu` taint, delete the pod so that its controller re-creates it. Ask the platform team
(s3df-help) if that does not help.

Kubernetes reference:
[taints and tolerations](https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/),
[assigning pods to nodes](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/),
[topology spread constraints](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/),
and [Node Feature Discovery](https://github.com/kubernetes-sigs/node-feature-discovery).
