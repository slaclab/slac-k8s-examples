# Node-local ZFS volumes (OpenEBS ZFS LocalPV)

A PersistentVolumeClaim in a ZFS LocalPV StorageClass gets a new, empty ZFS dataset on the local
disks of one node. It trades resilience for speed: the volume performs like a local disk, and it
exists on that one node only. Use it only for an application that keeps its own copies of the
data on several nodes, such as a replicated database, a Kafka cluster or a Raft cluster. For every
other volume, use a shared class; see [Storage: choosing a StorageClass](../README.md).

These classes are not a general service. Each one serves a node pool set aside for one workload,
and your vcluster can use a class only if the platform team has put it on your vcluster's
StorageClass allowlist. Ask the platform team (s3df-help) before you design for one, and see
[Your vcluster](../../vcluster/README.md#features-and-allowlists-the-platform-sets).

## What a claim gives you

- **One node.** The volume is a dataset in the ZFS pool of the node where its first pod is
  scheduled. Its PersistentVolume is pinned to that node for good, so every pod that uses the
  claim runs there.
- **A quota, not a reservation.** The requested size is the dataset's ZFS quota: the volume
  cannot hold more. The space is not set aside in the pool. The volumes on a node share its pool,
  and the scheduler checks the free space only when it places the volume, so a volume can run out
  of space before it reaches its quota if the pool fills.
- **One copy.** The platform does not replicate, snapshot or back up these volumes. While the node
  is down, the volume is unreachable. If the node's disks are lost, the data is lost.

## Who may use these classes, and why

Each class places volumes only on one node pool, through its `allowedTopologies`. The pool's
nodes carry a `NoSchedule` taint, so other workloads stay off them, and their disks, CPU and
memory go to the workload they were set aside for. Only that workload's vclusters have the class
on their allowlist.

| StorageClass | Node pool | Reserved for |
|---|---|---|
| `rubin-qserv-storage` | Rubin Qserv | Rubin Qserv |
| `zfs--rubin-efd`, `zfs-lscratch-storage` | Rubin Science Platform (RSP) | The Rubin Science Platform |
| `zfs--vault` | vcluster etcd | S3DF's Vault service |
| `zfs--vcluster-etcd` | vcluster etcd | Your vcluster's own etcd. Never use it |

`kubectl get storageclass` in your vcluster lists these classes with every other host class.
Seeing a class there does not mean you may use it: the host cluster (Kyverno) rejects a claim in a
class that is not on your vcluster's allowlist.

`zfs--vcluster-etcd` is on your allowlist only because your vcluster's etcd keeps its claims in
your host namespace, `vcluster--<name>`, where the allowlist applies. Its nodes are reserved for
the etcd of every vcluster: never use the class, and never tolerate its taint.

## How a claim reaches a node

Create the claim and the pods that use it inside your vcluster. The platform does the rest:

1. The vcluster syncs the claim to your host namespace, where Kyverno checks its class against
   your allowlist.
2. The claim stays `Pending` until a pod uses it: the classes bind with `WaitForFirstConsumer`.
3. The host scheduler picks a node for the pod that is in the class's node pool, whose taint the
   pod tolerates, and whose ZFS pool has enough free space for the request. The driver publishes
   each node's free pool space for this step (storage capacity tracking).
4. ZFS LocalPV creates the dataset on that node, and a PersistentVolume pinned to the node. The
   claim becomes `Bound`.
5. The kubelet mounts the dataset into the pod. This pod, and every later pod that uses the claim,
   runs on that node.

## Getting your pods onto the nodes

Your pods need the toleration for the pool's taint. The platform supplies it in one of two ways,
depending on the pool, and the platform team tells you which when it gives you a class.
[Node placement, taints and tolerations](../../scheduling/README.md) describes both.

| Pool | How the toleration arrives | What you do |
|---|---|---|
| A pool dedicated to your vcluster, such as Rubin Qserv | The vcluster adds the pool's toleration to every pod it syncs | Nothing |
| A pool with an annotation, such as RSP | The host (Kyverno) adds the toleration and a `nodeSelector` for the pool to pods that carry the annotation `edu.stanford.slac.sdf.project/rsp: "true"`, in the vclusters entitled to the pool | Put the annotation in the pod template, `spec.template.metadata.annotations`. In any other vcluster, the host rejects a pod that carries it |

Don't write tolerations for these taints yourself, and never a blanket toleration
(`operator: Exists` without a `key`); see
[Never tolerate every taint](../../scheduling/README.md#never-tolerate-every-taint). Don't add a
`nodeSelector` or node affinity for storage either: the PersistentVolume already places the pod.

## Claim settings

| Field | Value | What it is for |
|---|---|---|
| `storageClassName` | The class the platform team gave you. The examples use the placeholder `zfs--my-app` | Chooses the node pool |
| `accessModes` | `[ReadWriteOnce]` | The only mode the driver supports. The volume is on one node, so only pods on that node can mount it |
| `resources.requests.storage` | The space one replica needs, for example `10Gi` | The dataset's quota. It must fit in one node's free pool space when the first pod is scheduled |

In a StatefulSet, put these settings in `volumeClaimTemplates`, so that each replica gets its own
claim.

For a container that does not run as root, set `fsGroup` in the pod's `securityContext`: the
driver lets the kubelet give that group ownership of the volume when it mounts it. Add
`fsGroupChangePolicy: OnRootMismatch`, so that the kubelet skips the change when the volume's top
directory already has the right owner, which saves time on a volume with many files.

## Node pinning and data safety

- **A replica cannot move.** If its node is drained, rebooted or fails, the replica is down until
  the node is back: its pod cannot start on any other node. When the node returns, it must also
  have room for the pod's CPU and memory requests.
- **Replicate in the application.** Run enough replicas that the application keeps working, and
  keeps its data, with one replica down. Spread them with a required pod anti-affinity on
  `kubernetes.io/hostname`, so that no two replicas' volumes share a node.
- **PodDisruptionBudgets don't protect you.** Your vcluster does not sync them to the host, so a
  host drain does not wait for them. Your replication must survive replicas going away without
  warning; see [Disruptions](../../scheduling/disruptions/README.md).
- **Keep a copy of what you cannot rebuild.** Data that the other replicas cannot restore needs a
  backup, made by the application, to storage off the node, for example an S3 bucket or a
  [Weka](../weka/README.md) claim. Not every node pool can mount Weka: if your pods run only on
  their pool, ask the platform team which shared storage the pool's nodes can mount.

### Replacing a replica whose node will not return

Ask the platform team (s3df-help) whether the node will come back. If it will not, the replica's
volume is lost with it. To rebuild the replica on another node, delete its claim and then its pod:

```bash
kubectl delete pvc data-my-app-1 -n my-namespace --wait=false
kubectl delete pod my-app-1 -n my-namespace --wait=false
```

The claim goes once no pod uses it. The StatefulSet then creates the pod again, with a new, empty
claim, and the scheduler places both on another node of the pool with free space. Your
application copies the data back from the other replicas. If the old pod does not go away, ask
the platform team.

## Deleting a claim

The classes have reclaim policy `Delete`: deleting a claim destroys its dataset and the data in
it, and deleting a namespace deletes every claim in it. A StatefulSet keeps its claims when you
scale it down or delete it, unless its `persistentVolumeClaimRetentionPolicy` says `Delete`, so a
replica that comes back finds its old volume, on its old node. Delete those claims only when you
no longer need the data.

To restart a replica, delete its pod, not its claim.

## Examples

| File | What it shows |
|---|---|
| [`pvc.yaml`](pvc.yaml) | A claim for a new 10Gi dataset in the placeholder class `zfs--my-app` |
| [`pod.yaml`](pod.yaml) | A test pod for the claim: prints the volume's size and adds a line to a file on each run |
| [`service.yaml`](service.yaml) | The headless Service that gives each StatefulSet replica a stable DNS name |
| [`statefulset.yaml`](statefulset.yaml) | Three replicas, each with its own claim, on three different nodes |

Before you apply them, replace `zfs--my-app` with your class. If your pool uses an annotation, add
it to `metadata.annotations` in `pod.yaml` and to the pod template in `statefulset.yaml`. The
manifests set no namespace. Apply them to a namespace of your own with `-n`: platform policy
forbids the vcluster's `default` namespace, and [Your vcluster](../../vcluster/README.md) shows how
to create one.

```bash
kubectl apply -n my-namespace -f pvc.yaml -f pod.yaml
kubectl get pvc my-app-data -n my-namespace          # Pending until the pod is scheduled, then Bound
kubectl get pod my-app-test -n my-namespace -o wide  # NODE: the node that holds the volume
kubectl logs my-app-test -n my-namespace             # the volume's size, and one line per run

# Run it again: same node, one more line, because the volume kept its data.
kubectl delete pod my-app-test -n my-namespace --ignore-not-found
kubectl apply -n my-namespace -f pod.yaml

# Destroys the test volume and its data.
kubectl delete -n my-namespace --ignore-not-found -f pod.yaml -f pvc.yaml

kubectl apply -n my-namespace -f service.yaml -f statefulset.yaml
kubectl get pods -n my-namespace -l app=my-app -o wide  # one replica per node
kubectl get pvc -n my-namespace                         # data-my-app-0, data-my-app-1, data-my-app-2
```

`my-app-test` exits after each run. The platform deletes finished pods 10 to 25 minutes after
they are created, so read the log soon; see [Jobs and CronJobs](../../jobs/README.md). Deleting
the pod, by you or by the platform, leaves the claim and its data in place.

## Mistakes that break a claim or lose data

| Mistake | Result |
|---|---|
| A class that is not on your vcluster's allowlist, for example one copied from another project's manifests | The host cluster (Kyverno) rejects the synced claim, so it never binds. Ask the platform team |
| `zfs--vcluster-etcd` for application data | The allowlist accepts it, but its nodes are reserved for vcluster etcd and tainted, so the pod stays `Pending`. Never use it |
| No way onto the pool, for example a missing pool annotation | The pod and its claim stay `Pending`, with no error when you apply them. `kubectl describe pod` shows `had untolerated taint(s)` |
| A request bigger than any node's free pool space | The pod stays `Pending`: `did not have enough free storage` |
| One claim for several replicas, in a Deployment or with `ReadWriteMany` | Every pod that uses the claim runs on the volume's node, so the replicas share one node and one copy. Give each replica its own claim with `volumeClaimTemplates` |
| No required pod anti-affinity | Two replicas can land on one node, and losing that node loses both copies |
| A single replica holding data you cannot rebuild | A node failure takes it offline, and losing the node's disks loses the data |
| A `nodeSelector` or node affinity that excludes the volume's node | The pod stays `Pending`: `didn't match PersistentVolume's node affinity` |
| Deleting a claim to restart a replica, or deleting the claims left after a scale-down | The dataset and its data are destroyed (reclaim policy `Delete`) |
| Counting on a PodDisruptionBudget | It is not synced to the host, so host drains ignore it |

## Checking

```bash
# Every host class. Your vcluster may use only the ones on its allowlist.
kubectl get storageclass

# Pending: no pod that uses the claim has been scheduled yet.
kubectl get pvc -n my-namespace

# The node that holds a claim's volume (Node Affinity), even while no pod runs.
kubectl describe pv "$(kubectl get pvc data-my-app-0 -n my-namespace -o jsonpath='{.spec.volumeName}')"

# Why a pod is Pending: read the events at the end.
kubectl describe pod my-app-0 -n my-namespace

# Space used and left on a replica's volume. Less than the quota is left if the node's pool is filling.
kubectl exec my-app-0 -n my-namespace -- df -h /data
```

## Requesting a class

Ask the platform team (s3df-help). Tell them:

- what the application stores, and how it replicates its data between nodes;
- how many replicas it runs, and how much space and disk throughput each one needs;
- which vcluster needs the class.

The platform team decides whether node-local storage fits the workload, and on which nodes. If it
does, it puts a class on your vcluster's allowlist and tells you how your pods reach the pool.

Upstream references: [OpenEBS ZFS LocalPV](https://github.com/openebs/zfs-localpv),
[storage capacity tracking](https://kubernetes.io/docs/concepts/storage/storage-capacity/),
[StatefulSets](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/).
