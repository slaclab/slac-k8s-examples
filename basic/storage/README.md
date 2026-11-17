# Choosing a StorageClass (Weka, S3DF filesystems, node-local ZFS)

A PersistentVolumeClaim asks for storage, and its StorageClass decides what the claim gets: a new,
empty volume on Weka, a way into an existing S3DF filesystem share, or a new volume on one node's
local disks. This page helps you choose a class. It also says which classes your vcluster may use
and what the platform does and does not back up. Each kind of storage has its own guide.

Your vcluster can use only the classes on its StorageClass allowlist, which the platform team sets
per vcluster. The Weka class is on every allowlist; the platform team adds other classes on
request. See [Your vcluster](../vcluster/README.md#features-and-allowlists-the-platform-sets).

## Choosing a class

| You need | Use |
|---|---|
| A new volume for a database, a queue, uploaded files or other state your application owns | `wekafs--sdf-k8s01`, the default class: [Weka volumes](weka/README.md) |
| Files that already live on an S3DF share, such as `/sdf/group/<facility>` or `/sdf/data/<facility>`, or results that S3DF users must reach outside Kubernetes | The class for that share: [S3DF filesystems](sdf-filesystem/README.md) |
| Local-disk performance, for an application that keeps its own copies of the data on several nodes | A node-local ZFS class that the platform team sets up for your workload: [Node-local ZFS](node-local-zfs/README.md) |
| Scratch space and caches that may disappear with the pod | An `emptyDir` volume, without a claim: see [Scratch space](#scratch-space-emptydir) |

## The three kinds of storage

| | [Weka](weka/README.md) | [S3DF filesystem (LPP)](sdf-filesystem/README.md) | [Node-local ZFS](node-local-zfs/README.md) |
|---|---|---|---|
| StorageClass | `wekafs--sdf-k8s01`, the default | One per share, for example `sdf-group-<facility>`, `sdf-data-<facility>`, `sdf-home` or `sdf-scratch` | One per workload, named by the platform team |
| Provisioner | `csi.weka.io` | `local-path-provisioner.local/<class>` | `zfs.csi.openebs.io` |
| A new claim gets | A new, empty directory of its own, on a Weka filesystem for Kubernetes volumes, separate from the `/sdf` shares | The whole existing share. Every claim in the class sees the same files | A new, empty ZFS dataset on one node. Every pod that uses it runs on that node |
| Access modes | `ReadWriteOnce`, `ReadWriteOncePod` or `ReadWriteMany` | `ReadWriteMany` only | `ReadWriteOnce` |
| Size | `requests.storage` is a hard quota. You can raise it later | Not enforced | `requests.storage` is the dataset's quota |
| Bound | When the claim is created (`Immediate`) | When the first pod that uses the claim is scheduled (`WaitForFirstConsumer`) | When the first pod that uses the claim is scheduled (`WaitForFirstConsumer`) |
| Deleting the claim | Deletes the volume and its data | Removes only the claim and its PV. The files stay on the share | Deletes the volume and its data |
| Who may use it | Every vcluster | Vclusters with the class on their allowlist, added on request | Only the workloads the platform team sets the class up for |

The S3DF filesystem classes are served by the Local Path Provisioner (LPP), one class per share.
Classes whose names start with `fs-ddn-` are LPP classes too: they mount paths under
`/fs/ddn/sdf/` instead of `/sdf/`.

The platform sets no ResourceQuota, so nothing limits how many claims you create or their total
size. Only the class limits the size of a claim, as the table shows. Request what the application
needs.

## How a claim gets its storage

Create the claim inside your vcluster: directly, through a StatefulSet's `volumeClaimTemplates`, or
through a Helm chart or an operator. The platform does the rest:

1. The vcluster syncs the claim to your host namespace, `vcluster--<name>`. A claim without
   `storageClassName` has the default class by then.
2. The host cluster (Kyverno) checks the claim's class against your vcluster's allowlist, and
   rejects a claim in any other class. A rejected claim stays `Pending` in your vcluster, with a
   `SyncError` event: see [Reading a rejection](../platform-policies/README.md#reading-a-rejection).
3. The class's provisioner creates a PersistentVolume: at once for Weka, and for LPP and ZFS when
   the first pod that uses the claim is scheduled. The claim becomes `Bound` in your vcluster.

Platform policy forbids `hostPath` volumes in your pods, because a host directory gives a pod the
node's files and a way to escalate privileges. A claim is the supported way to get storage; see
[Platform policies](../platform-policies/README.md).

## Which classes your vcluster may use

`kubectl get storageclass` in your vcluster lists every StorageClass on the host cluster: the
vcluster copies them in from the host, read-only. Most of them serve other facilities' shares or
nodes reserved for other workloads, and your vcluster cannot use them unless the platform team adds
them to its allowlist.

The allowlist applies to every claim in your host namespace, including the claims that
StatefulSets, charts and operators create. The platform keeps one list per vcluster because many
classes open a whole facility share or use nodes reserved for one workload, so each vcluster gets
only the classes it needs. Every list includes `wekafs--sdf-k8s01`.

The list lives on the host cluster, so you cannot read it from your vcluster. Ask the platform
team, or look at the classes your bound claims already use (see [Checking](#checking)).

StorageClasses you create in your vcluster do not reach the host cluster. StorageClasses are
cluster-wide objects on the host, shared by every vcluster, so the vcluster does not sync yours. No
provisioner serves them, and the allowlist rejects claims in them.

To get another class, ask the platform team (s3df-help, `s3df-help@slac.stanford.edu`). Name your
vcluster and give:

- for an S3DF share, its path, for example `/sdf/data/<facility>`;
- for node-local ZFS, what the application stores and how it keeps copies on other nodes: see
  [Requesting a class](node-local-zfs/README.md#requesting-a-class).

## The default class

`wekafs--sdf-k8s01` is the default StorageClass. A claim without `storageClassName` gets a Weka
volume and passes every allowlist, so charts and operators that leave the class unset work without
changes. Name the class in your own manifests anyway, so that a reader sees where the data lives, as
[`weka/pvc.yaml`](weka/pvc.yaml) does.

`storageClassName: ""`, an empty string, is not the same as leaving the field out. It asks for no
class, so no provisioner creates a volume, and the allowlist rejects the claim. A chart can render
an empty string from an empty value: check what it renders, for example with `helm template`,
before you install it.

## Reserved classes

`zfs--vcluster-etcd` is on your allowlist by default, but it is not for your workloads: it holds
your vcluster's own etcd. It is on the list because the etcd claims live in your host namespace
too, where the allowlist checks every claim. Its volumes can only be on nodes reserved for vcluster
etcd, which carry a taint your pods do not tolerate, so a pod with a claim in this class stays
`Pending`. Never use it, and never add a toleration for those nodes: they run the etcd of every
vcluster.

The other node-local ZFS classes each serve one workload's dedicated nodes, and only that
workload's vclusters have them on their allowlists. See [Node-local ZFS](node-local-zfs/README.md).

## What the platform backs up

The platform backs up each vcluster's etcd, which stores the Kubernetes objects you create:
Deployments, ConfigMaps, Secrets, and the claims themselves. It copies etcd to S3 object storage
once a day and keeps frequent ZFS snapshots of the etcd volumes; see
[What is backed up](../vcluster/README.md#what-is-backed-up). These copies hold objects, not the
files in your volumes.

Volume snapshots are not available, and the platform's backups do not include the data in your
volumes. Your vcluster has no VolumeSnapshotClass: the vcluster does not import the host's classes,
and the host has none for tenant volumes. Treat every volume as having no backup unless your
application makes one.

| Storage | Volume snapshots | When the claim is deleted | Where the data lives |
|---|---|---|---|
| Weka | Not available. The platform keeps Weka snapshots of these volumes off, because each one would be a snapshot of the whole shared filesystem | The data is deleted | On the shared Weka filesystem, reachable from any node with the Weka client |
| S3DF filesystem (LPP) | Not available. LPP is not a CSI driver and has no snapshot support | The files stay on the share | On the S3DF share itself. Files deleted through the mount are gone from the share for every S3DF user |
| Node-local ZFS | Not available | The data is deleted | On one node only: unreachable while the node is down, and lost if the node's disks are lost |

Deleting a namespace deletes every claim in it, so on Weka and ZFS it deletes their data. Deleting a
StatefulSet keeps its claims, unless its `persistentVolumeClaimRetentionPolicy` says `Delete`.

Keep your own copies of data you cannot recreate, made by the application. For PostgreSQL, use
backups to S3 ([CloudNativePG backups](../../operators/cloudnativepg/backups/README.md)). Don't
configure backups that depend on volume snapshots, such as CloudNativePG `backup.volumeSnapshot` or
`method: volumeSnapshot`.

## Scratch space (emptyDir)

An `emptyDir` volume needs no claim and no StorageClass. It lives on the disk of the node the pod
runs on, the pod's containers share it, and it is deleted with the pod. Use it for caches and
temporary files. It counts towards the pod's ephemeral storage, which every pod on the node draws
from the same disk: set ephemeral-storage requests and limits and a `sizeLimit`, as
[Ephemeral storage](../resources/README.md#ephemeral-storage) describes. An `emptyDir` with
`medium: Memory` uses the node's memory instead; see
[Memory-backed emptyDir](../resources/README.md#memory-backed-emptydir). For scratch data that must
outlive the pod, or that is too large for the node's disk, use a Weka claim.

## Mistakes that leave a claim Pending or lose data

| Mistake | Result |
|---|---|
| Picking a class from `kubectl get storageclass` | The list shows every class on the host cluster. A class that is not on your allowlist is rejected, and the claim stays `Pending`. Ask the platform team |
| A chart's default class, for example `standard`, `gp2`, `local-path` or `longhorn` | No such class exists on the host, and it is not on your allowlist: the claim stays `Pending`. Set the chart's storage class value to `wekafs--sdf-k8s01`, or leave it unset |
| `storageClassName: ""` | No class: no volume is created, and the allowlist rejects the claim |
| A StorageClass of your own, created in the vcluster | It does not reach the host, so its claims stay `Pending` |
| `zfs--vcluster-etcd` for application data | Reserved for your vcluster's etcd. The pod cannot be scheduled and stays `Pending` |
| A Weka claim to reach `/sdf/group`, `/sdf/data` or another S3DF share | You get a new, empty directory, not the share. Use the share's LPP class |
| Deleting a Weka or ZFS claim, its namespace, or a StatefulSet whose retention policy says `Delete`, while the data still matters | The volume and its data are deleted at once, and there is no snapshot to restore from |
| Backups that depend on volume snapshots | Not available. Back up at the application level instead |
| Creating or editing PersistentVolumes yourself | Not supported. Get storage only through claims, and leave the PersistentVolumes the provisioners create alone |
| Node-local ZFS for data that has only one copy | The data exists on one node. Pods that use it cannot run while the node is down, and the data is lost with the node's disks |

## Checking

```bash
# Every StorageClass on the host cluster. Your vcluster may use only the ones on its allowlist.
kubectl get storageclass \
  -o custom-columns=NAME:.metadata.name,PROVISIONER:.provisioner,RECLAIM:.reclaimPolicy,BINDING:.volumeBindingMode

# Every claim in your vcluster, with its class and status: the classes you already use.
kubectl get pvc -A \
  -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,CLASS:.spec.storageClassName,STATUS:.status.phase

# A claim that stays Pending: its events, and any rejection by the host.
kubectl describe pvc my-app-data -n my-namespace
kubectl get events -n my-namespace --field-selector reason=SyncError
```

A Weka claim binds at once. An LPP or ZFS claim stays `Pending` until a pod that uses it is
scheduled, and that is expected. If a claim is still `Pending` after that, read its events, and ask
the platform team (s3df-help) if they do not explain why.

Upstream reference: [storage classes](https://kubernetes.io/docs/concepts/storage/storage-classes/)
and [persistent volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/) in the
Kubernetes documentation.
