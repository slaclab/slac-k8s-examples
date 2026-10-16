# Disruptions and high availability (host node drains, failures and preemption)

Your pods run on shared nodes of the host cluster, and they stop when the platform drains a node
for maintenance, when a node fails, or when a platform pod needs the room. Nothing in your vcluster
holds these off: PodDisruptionBudgets and PriorityClasses are not synced to the host. An
application stays up through them only by running several replicas on different nodes that start,
stop and receive traffic cleanly. This guide shows how.

What your vcluster syncs to the host, and what it does not, is in
[Your vcluster](../../vcluster/README.md#what-reaches-the-host-cluster).

## What stops your pods

| Event | What happens to your pods |
|---|---|
| Node drain | The platform drains nodes for upgrades. Every pod on the node is evicted: it gets `SIGTERM`, then its `terminationGracePeriodSeconds`, then it is killed. A Deployment or StatefulSet starts a replacement on another node |
| Node failure | The node stops reporting. Its pods are replaced elsewhere after a delay; see [Node failures](#node-failures) |
| Preemption | A platform pod or a vcluster control plane that does not fit on a node evicts lower-priority pods there, which includes every tenant pod. See [Priority and preemption](#priority-and-preemption) |
| Node pressure | A node that runs short of memory or disk evicts pods, first those using more than they request. Set requests that match real use: see [Resources](../../resources/README.md) |

An evicted pod ends `Failed`, and the host deletes finished pods within minutes, so look at its
events soon; see [Jobs](../../jobs/README.md). As the platform configures them, its descheduler and
draino run in dry-run mode: they report what they would evict and evict nothing.
node-problem-detector reports kernel problems as node conditions and events, and evicts nothing
itself.

## PodDisruptionBudgets do not protect you

Your vcluster accepts a PodDisruptionBudget and shows it with `kubectl get pdb`, but does not sync
it to the host. Drains and evictions happen on the host, which never sees the budget, so a drain
evicts all your replicas on that node at once and does not wait. Because budgets stay inside
your vcluster, no tenant workload can hold up the drain of a node that every vcluster shares.

Instead of a budget:

- Run at least two replicas, three for anything users depend on, spread over nodes. A drain of
  one node then stops one replica.
- Use `maxUnavailable: 0` in a Deployment's rollout, so that your own updates never lower the
  number of ready replicas.
- A single replica is down on every drain of its node. Accept that, or add replicas.

## Priority and preemption

On the host, the platform's own services run at the highest priority, every vcluster's control
plane just below them, and all tenant pods at priority 0. The platform orders them this way so
that the services the cluster and every vcluster depend on keep running when nodes are full.

- A platform pod or a vcluster control plane that cannot be placed can preempt your pods. The
  victims get `SIGTERM` and their grace period, like a drain.
- Your vcluster's control plane outranks your workloads, so your vcluster's API keeps working when
  nodes are full.
- Tenant pods all have the same priority, so they never preempt each other: no tenant can buy room
  at another's expense.
- A PriorityClass and `priorityClassName` in your vcluster change nothing on the host. Leave them
  unset. See [Node placement](../README.md#priority-classes).

## Node failures

When a node stops reporting, the host marks it `NotReady` and taints it
`node.kubernetes.io/unreachable` or `node.kubernetes.io/not-ready` with effect `NoExecute`. Pods
tolerate these taints for 300 seconds by default and are then marked for deletion, which cannot
finish while the node is down.

| Workload | Replacement |
|---|---|
| Deployment | A new pod starts on another node once the old one is marked for deletion. The default is about five minutes after the node is marked `NotReady`; `tolerationSeconds` makes it shorter, as in [`deployment-ha.yaml`](deployment-ha.yaml) |
| StatefulSet | The replica is not recreated until the old pod is fully gone, so that two pods never run with one identity. Its `ReadWriteOnce` volume stays attached to the failed node |
| Pod on a [node-local ZFS volume](../../storage/node-local-zfs/README.md) | None. The volume is on the failed node, so the replica is down until the node returns |

For many of its nodes, the platform also has a policy that taints a node whose `Ready` condition
turns `Unknown` with `node.kubernetes.io/out-of-service=unreachable:NoExecute`. This is Kubernetes' [non-graceful node shutdown](https://kubernetes.io/docs/concepts/cluster-administration/node-shutdown/#non-graceful-node-shutdown)
handling: pods that do not tolerate the taint are deleted at once, and their volumes are detached,
so StatefulSet replicas and their volumes start on another node. The platform does this so that a
dead node does not hold replicas and their volumes until someone recovers it.

All of this works only for pods that do not tolerate these taints indefinitely. Never write a
toleration without a `key` ([Never tolerate every taint](../README.md#never-tolerate-every-taint)),
and give every `NoExecute` toleration a `tolerationSeconds`.

If a StatefulSet replica stays `Terminating` on a `NotReady` node, ask the platform team
(s3df-help). Don't force-delete it: Kubernetes
[warns](https://kubernetes.io/docs/tasks/run-application/force-delete-stateful-set-pod/) that a
forced delete of a pod whose node may still run it can leave two pods with one identity writing
the same data.

## Running highly available

| Setting | Value | Why |
|---|---|---|
| `replicas` | `3` | One drain, failure or preemption stops one replica |
| `topologySpreadConstraints` | `topologyKey: kubernetes.io/hostname`, `whenUnsatisfiable: ScheduleAnyway` | Replicas on different nodes, so that one node stops one replica. See [Spreading replicas](../README.md#spreading-replicas) |
| `podAntiAffinity` | `requiredDuringSchedulingIgnoredDuringExecution` on `kubernetes.io/hostname` | Never two replicas on one node, for replicated stateful workloads. A replica that cannot get a node of its own stays `Pending` |
| `readinessProbe` | A check of the application itself | A Service sends traffic only to ready replicas, so a starting replica gets none |
| `lifecycle.preStop` | `sleep: {seconds: 5}` | The replica keeps serving while the Service stops sending it traffic |
| `terminationGracePeriodSeconds` | Long enough for the preStop hook and a clean shutdown | After it the container is killed. Handle `SIGTERM` in your application |
| `strategy.rollingUpdate` | `maxUnavailable: 0`, `maxSurge: 1` | A rollout starts each new replica before it stops an old one |
| `podManagementPolicy` | `Parallel` (StatefulSet, at creation only) | A replica stuck on a failed node does not hold up the others |
| Storage | One Weka volume per replica, from `volumeClaimTemplates` | A Weka volume mounts on any node with the Weka client, so a replica that moves keeps its data. See [Weka volumes](../../storage/weka/README.md) |

Replicas of a database must copy their data between themselves, which the database does, not
Kubernetes. For PostgreSQL and other databases, an operator does this and replaces failed
replicas: see [Operators](../../../operators/README.md).

## Examples

| File | What it shows |
|---|---|
| [`deployment-ha.yaml`](deployment-ha.yaml) | A stateless Deployment: three replicas spread over nodes, readiness probe, preStop hook, rollout without lost capacity, and 30-second failover from a failed node |
| [`service.yaml`](service.yaml) | The Service in front of it, which sends traffic only to ready replicas |
| [`statefulset-ha.yaml`](statefulset-ha.yaml) | A StatefulSet: three replicas on three nodes, each with its own Weka volume, `Parallel` pod management and no tolerations |
| [`service-headless.yaml`](service-headless.yaml) | The headless Service of the StatefulSet, which gives each replica a stable DNS name |

```bash
kubectl apply -n my-namespace -f deployment-ha.yaml -f service.yaml
kubectl apply -n my-namespace -f service-headless.yaml -f statefulset-ha.yaml
```

## Mistakes that cost availability

| Mistake | Result |
|---|---|
| One replica | Down on every drain, failure or preemption of its node |
| Relying on a PodDisruptionBudget | It is not synced: a drain evicts every replica on the node at once |
| Setting `priorityClassName` | No effect on the host: the pod stays at priority 0 |
| Replicas without spreading | Several can land on one node and stop together |
| A toleration with `operator: Exists` and no `key` | The pod is never moved off a failed node, and a StatefulSet replica and its volume stay there |
| A `NoExecute` toleration without `tolerationSeconds` | The same, for that taint |
| No readiness probe | Traffic reaches replicas that are still starting |
| An application that ignores `SIGTERM` | It is killed at the end of the grace period, mid-request |
| A Deployment with several replicas on one `ReadWriteOnce` claim | Replicas on other nodes wait with a `Multi-Attach error`, and failover stalls. Use a StatefulSet or `ReadWriteMany` |
| Data on a node-local volume without replication in the application | The data is unreachable while its node is down |
| Force-deleting a `Terminating` StatefulSet pod | Two pods can run with one identity. Ask the platform team instead |

## Checking

```bash
# Which node each replica runs on: no two replicas should share one.
kubectl get pods -n my-namespace -l app=my-app -o wide

# Nodes your pods run on, and any that are NotReady.
kubectl get nodes

# The taints of a node, for example node.kubernetes.io/out-of-service after a failure.
kubectl get node <node-name> -o jsonpath='{.spec.taints}'

# Pods that were preempted, and the evictions and failures behind other restarts.
kubectl get events -n my-namespace --field-selector reason=Preempted
kubectl get events -n my-namespace --sort-by=.lastTimestamp

# Whether a rollout finished without losing ready replicas.
kubectl rollout status deployment/my-app -n my-namespace
```

Upstream reference:
[disruptions](https://kubernetes.io/docs/concepts/workloads/pods/disruptions/),
[pod priority and preemption](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/),
[taint-based evictions](https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/#taint-based-evictions),
[node-pressure eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/).
