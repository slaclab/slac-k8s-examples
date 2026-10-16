# Persistent volumes for your application (Weka CSI)

A PersistentVolumeClaim in the StorageClass `wekafs--sdf-k8s01` gives your workload a new, empty
volume of its own on Weka, a network filesystem that pods mount from any node with the Weka
client. Use it for state that belongs to the application: databases, queues, uploaded files,
caches that must survive a restart. It is the default class, and it is on every vcluster's
StorageClass allowlist by default (see [Your vcluster](../../vcluster/README.md#features-and-allowlists-the-platform-sets)). To reach data
that already exists on an S3DF share such as `/sdf/data/<facility>`, use an
[S3DF filesystem claim](../sdf-filesystem/README.md) instead.
[Storage: choosing a StorageClass](../README.md) compares all the classes.

## What a claim gives you

- **A private, empty directory.** Each claim gets a directory of its own on the Weka filesystem
  `sdf-k8s01`, on a Weka cluster that serves the Kubernetes platform. It is not part of the
  `/sdf` filesystems. Only pods that mount the claim see it.
- **A hard quota.** `resources.requests.storage` is the size limit of the directory. Once it is
  full, writes fail until you free space or grow the claim. Every claim in every vcluster lives
  on the same filesystem, and the quota keeps each claim within the size it asked for.
- **Any node.** Every node with the Weka client mounts the same volume, so a pod that moves to
  another node keeps its data.
- **Deleted with the claim.** The reclaim policy is `Delete`: deleting the claim deletes the
  directory and every file in it.

## Weka or an S3DF filesystem?

| | Weka (`wekafs--sdf-k8s01`) | S3DF filesystem (LPP classes) |
|---|---|---|
| A claim gives you | A new, empty directory of its own | An existing `/sdf` share, the whole tree |
| Size | Enforced: the request is a hard quota | Not enforced |
| Deleting the claim | Deletes the data | Leaves the data on the share |
| Binding | At once (`Immediate`) | When a pod first uses it (`WaitForFirstConsumer`) |
| Access modes | `ReadWriteOnce`, `ReadWriteOncePod`, `ReadWriteMany` | `ReadWriteMany` only |
| Who may use it | Every vcluster, by default | Classes on your vcluster's allowlist, on request |

Choose Weka for data your application owns. Choose an S3DF filesystem for data that S3DF users
and systems outside your vcluster also read or write. Workloads that need a node-local disk, and
keep their own copies of the data on other nodes, can ask the platform team for
[Node-local ZFS volumes](../node-local-zfs/README.md).

## How a claim becomes a volume

Create the claim inside your vcluster, directly or through a StatefulSet's `volumeClaimTemplates`,
a Helm chart or an operator. The platform does the rest:

1. The vcluster syncs the claim to the host cluster, into the namespace `vcluster--<name>`.
2. The host cluster (Kyverno) checks the claim's class against your vcluster's StorageClass
   allowlist.
3. The Weka CSI driver creates the directory, sets its quota to the requested size, and creates a
   PersistentVolume. Binding is `Immediate`: the claim is `Bound` before any pod uses it, because
   every node with the Weka client reaches the volume.
4. When a pod that uses the claim starts, the node's Weka client mounts the directory into it.
   The mount does not use NFS.

The PV carries a node affinity on the Weka labels of the nodes, so pods that mount the volume run
only on nodes with the Weka client. Don't add a `nodeSelector`, node affinity or tolerations for
storage: the volume does not need them, and one that sends the pod to a node without the client
leaves the pod `Pending`. See [Node placement](../../scheduling/README.md).

## Claim settings

| Field | Value | What it is for |
|---|---|---|
| `storageClassName` | `wekafs--sdf-k8s01` | Chooses Weka. A claim without the field gets it too, because it is the default; name it anyway, so the manifest shows where the data lives |
| `accessModes` | `[ReadWriteOnce]`, `[ReadWriteOncePod]` or `[ReadWriteMany]` | Which pods may mount the volume, see below |
| `resources.requests.storage` | A size, for example `10Gi` | The hard quota of the directory |
| `volumeMode` | `Filesystem` (the default) | The driver provides filesystems only. It refuses `Block` |

| Access mode | Who can mount the volume | Use it for |
|---|---|---|
| `ReadWriteOnce` | Pods on one node at a time. A pod on a second node waits with a `Multi-Attach error` | A single writer, for example a database or a StatefulSet replica's own data |
| `ReadWriteOncePod` | One pod in the whole cluster | The same, when Kubernetes must guarantee a single writer |
| `ReadWriteMany` | Any number of pods on any nodes | Data shared by several replicas. The application coordinates its own writers |
| `ReadOnlyMany` | Not useful: a new volume is empty | Nothing. Pods that only read shared data mount a `ReadWriteMany` claim with `readOnly: true` on the `volumeMount` |

## Growing a claim

Raise `resources.requests.storage` in the claim and apply it again. The driver raises the
directory's quota while the pods keep running: nothing restarts, and the claim's
`status.capacity` shows the new size when it is done. The class allows expansion, so start with
the size you need now and grow the claim before it fills.

- A claim cannot shrink. Kubernetes refuses a request below the current size.
- Kubernetes does not allow changes to a StatefulSet's `volumeClaimTemplates`. Grow each claim
  instead, for example `data-my-app-db-0`.
- Claims that an operator manages, for example for [CloudNativePG](../../../operators/cloudnativepg/README.md),
  are sized in the operator's own resource. See the operator's guide for growing them.

## Deleting a claim

Deleting a claim deletes the directory and its files. Treat it as permanent: there is no
VolumeSnapshot to restore from. Data is also deleted when you delete:

- the namespace that holds the claim;
- a StatefulSet whose `persistentVolumeClaimRetentionPolicy` is `whenDeleted: Delete`, or the
  replicas it scales away with `whenScaled: Delete`;
- an operator-managed database whose operator removes its claims with it.

Don't change the reclaim policy of a Weka PV. Changes to a PV in your vcluster reach the PV on the
host cluster. With `Retain`, the directory and its quota stay on the shared filesystem after the
claim is gone, and only the platform team can remove them. If data must outlive its claim, ask
the platform team (s3df-help).

To use a volume again after a claim is deleted, apply the claim from your own manifest. Don't
re-create it from `kubectl get pvc -o yaml` output: that carries the `volumeName` of the deleted
PV, so the claim never binds.

## Snapshots and backups

You cannot take a VolumeSnapshot of a Weka volume: no VolumeSnapshotClass exists for the Weka
driver, and the driver's snapshots of directory volumes are off. The platform keeps them off
because each one would be a snapshot of the whole shared filesystem.

Back up data you cannot recreate with your application's own tools, for example
[CloudNativePG backups to S3](../../../operators/cloudnativepg/backups/README.md) for PostgreSQL.
For files, a CronJob can copy them to an S3DF share through an LPP claim; see
[Jobs and CronJobs](../../jobs/README.md).

## Permissions and performance

- The class creates the root directory of each volume with mode `0777`, so a container running
  as any user, including a non-root one, can write to it without an `fsGroup`.
- With `securityContext.fsGroup`, the kubelet changes the group of every file on the volume each
  time a pod starts. On a volume with many files this delays every start. Add
  `fsGroupChangePolicy: OnRootMismatch` to skip the change when the root directory already has
  the right group, as in [`deployment.yaml`](deployment.yaml).
- Every read and write goes over the network to the Weka cluster, which every claim in every
  vcluster shares. A [node-local ZFS volume](../node-local-zfs/README.md) uses a disk in the node
  instead, at the cost of tying the pod to that node.

## Examples

| File | What it shows |
|---|---|
| [`pvc.yaml`](pvc.yaml) | A 10Gi `ReadWriteOnce` claim |
| [`deployment.yaml`](deployment.yaml) | One non-root replica using that claim, with `fsGroup`, `OnRootMismatch` and the `Recreate` strategy |
| [`statefulset.yaml`](statefulset.yaml) | A StatefulSet whose replicas each get their own volume from `volumeClaimTemplates`, with the retention policy spelled out |
| [`pvc-shared.yaml`](pvc-shared.yaml) | A 10Gi `ReadWriteMany` claim |
| [`deployment-shared.yaml`](deployment-shared.yaml) | Three replicas, on any nodes, sharing that claim |

The manifests set no namespace. Apply them to a namespace of your own with `-n`: platform policy
forbids the vcluster's `default` namespace, and [Your vcluster](../../vcluster/README.md) shows how
to create one. `deployment.yaml` uses the claim from `pvc.yaml`, and `deployment-shared.yaml` the
claim from `pvc-shared.yaml`. `statefulset.yaml` creates its own claims.

## Mistakes that lose data or break a claim

| Mistake | Result |
|---|---|
| Using this class to reach `/sdf/data`, `/sdf/group` or another S3DF share | You get a new, empty directory on the Kubernetes Weka filesystem, not the share. Use an [S3DF filesystem claim](../sdf-filesystem/README.md) |
| Deleting a claim, its namespace, or a StatefulSet with `whenDeleted: Delete`, while the data still matters | The data is deleted, and there is no VolumeSnapshot to restore from |
| Sizing the claim for today's data only | Writes fail when the quota is full, and a database can stop. Grow the claim before it fills |
| A Deployment with several replicas, or the `RollingUpdate` strategy, on a `ReadWriteOnce` claim | Pods on other nodes wait with a `Multi-Attach error`, and a rollout stalls. Use `ReadWriteMany`, a StatefulSet, or `strategy: Recreate` for a single replica |
| `ReadOnlyMany` | An empty volume, with no data to read |
| Raising the size in a StatefulSet's `volumeClaimTemplates` | The API server refuses the change. Grow each claim instead |
| A smaller `resources.requests.storage` | Refused. Claims only grow |
| `storageClassName: ""` instead of leaving the field out | An empty string asks for no class, not the default. The allowlist rejects it, and the claim never binds |
| `volumeMode: Block` | The driver refuses to create the volume, and the claim stays `Pending` |
| A `nodeSelector` or tolerations that send the pod to nodes without the Weka client | The pod stays `Pending`: `didn't match PersistentVolume's node affinity` |
| `fsGroup` without `fsGroupChangePolicy: OnRootMismatch` on a volume with many files | Every pod start waits while the kubelet changes the group of every file |
| Setting the PV's reclaim policy to `Retain` | The directory and its quota stay on the shared filesystem after the claim is deleted, until the platform team removes them |
| Creating a VolumeSnapshot of the claim | Not possible: no VolumeSnapshotClass exists for Weka |

## Checking

```bash
kubectl apply -n my-namespace -f pvc.yaml -f deployment.yaml
kubectl get pvc my-app-data -n my-namespace    # Bound at once, before the pod starts

# The PV: reclaim policy Delete, class wekafs--sdf-k8s01.
kubectl get pv "$(kubectl get pvc my-app-data -n my-namespace -o jsonpath='{.spec.volumeName}')"

# The claim's directory on the Weka filesystem: dir/v1/sdf-k8s01/csi-volumes/pvc-...
kubectl get pv "$(kubectl get pvc my-app-data -n my-namespace -o jsonpath='{.spec.volumeName}')" \
  -o jsonpath='{.spec.csi.volumeHandle}{"\n"}'

# Space in use. The claim's size is the limit.
kubectl exec -n my-namespace deploy/my-app -- du -sh /data

# Grow the claim to 20Gi (or raise the size in pvc.yaml and apply it again), then check.
kubectl patch pvc my-app-data -n my-namespace -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'
kubectl get pvc my-app-data -n my-namespace -o jsonpath='{.status.capacity.storage}{"\n"}'

# A claim that stays Pending, or a pod that waits for its volume: the events say why.
kubectl describe pvc my-app-data -n my-namespace
kubectl describe pod -n my-namespace -l app=my-app

# A StatefulSet: one claim per replica, named <template>-<statefulset>-<ordinal>.
kubectl apply -n my-namespace -f statefulset.yaml
kubectl get pvc data-my-app-db-0 data-my-app-db-1 -n my-namespace
```

The StorageClass parameters are described in the Weka CSI plugin's
[storage class configuration](https://docs.weka.io/appendices/weka-csi-plugin/storage-class-configurations)
(directory-backed volumes, `volumeType: dir/v1`). The Kubernetes documentation explains
[fsGroupChangePolicy](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/#configure-volume-permission-and-ownership-change-policy-for-pods).
