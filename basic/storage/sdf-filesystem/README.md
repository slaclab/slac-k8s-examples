# S3DF filesystems in a pod (Local Path Provisioner)

A PersistentVolumeClaim in an S3DF Local Path Provisioner (LPP) StorageClass mounts an existing
S3DF share into your pods, for example `/sdf/group/<facility>` or `/sdf/data/<facility>`. Each
class serves one share. A claim is a way into the data already on that share: it is not a new,
empty volume. For a new, empty volume, see [Storage: choosing a StorageClass](../README.md).
Your vcluster can use only the classes on its allowlist, which the platform team sets per
vcluster: see [Your vcluster](../../vcluster/README.md#features-and-allowlists-the-platform-sets).

## What a claim gives you

- **The whole share.** Every claim in a class points at the same share root and sees the whole
  tree. Claims are not isolated from each other, and file permissions on the share still apply.
- **No quota.** `resources.requests.storage` is required by Kubernetes but not enforced. Any value
  works; the examples use `1Gi`.
- **Many pods, many nodes.** Every pod that uses the claim, on any node, sees the same files. The
  application must coordinate its own writers.

## How a claim reaches the share

Create the claim and the pods that use it inside your vcluster. The platform does the rest:

1. The vcluster syncs the claim to the host cluster.
2. The claim stays `Pending` until a pod uses it: the classes bind with `WaitForFirstConsumer`.
3. When the pod is scheduled, LPP creates a PersistentVolume that points at the share root, and
   the claim becomes `Bound`.
4. The kubelet mounts the share into the pod. From then on, reads and writes go straight to the
   filesystem.

The PV carries a node affinity on a storage label that the platform keeps on the nodes that mount
S3DF storage, so the scheduler places your pods on those nodes. Don't add a `nodeSelector` or
node affinity of your own for storage.

`hostPath` volumes are forbidden in tenant namespaces, so a claim in a class on your vcluster's
allowlist is the supported way to reach a share. This lets the platform decide which vcluster can
reach which facility's data. Ask the platform team (s3df-help) which classes your vcluster may
use, and to add a share you need.

## Classes and their share roots

The class name follows the share root:

| Class | Share root | What the pod sees |
|---|---|---|
| `sdf-group-<facility>`, for example `sdf-group-ad` | `/sdf/group/<facility>` | The facility's group space |
| `sdf-data-<facility>`, for example `sdf-data-ad` | `/sdf/data/<facility>` | The facility's data space |
| `sdf-scratch` | `/sdf/scratch` | The whole scratch tree, not only your part of it |
| `sdf-scratch-rubin` | `/sdf/scratch/rubin` | Rubin's scratch space |
| `sdf-home` | `/sdf/home` | The home directories of every S3DF user, not only yours |
| `fs-ddn-sdf-group-<facility>` | `/fs/ddn/sdf/group/<facility>` | The facility's group space on the DDN filesystem |
| `fs-ddn-sdf-home` | `/fs/ddn/sdf/home` | The home tree on the DDN filesystem |

The `/sdf/...` roots are on S3DF's Weka storage, and the `/fs/ddn/sdf/...` roots on its DDN
filesystem. Choose the class whose share root holds your data. A few classes serve a
subdirectory, for example `sdf-group-cryoem-exp` serves `/sdf/group/cryoem/exp`. One name does
not follow the pattern: `sdf-group-cryoem-dev` serves `/fs/ddn/sdf/group/cryoem/dev`, on DDN.

`kubectl get storageclass` in your vcluster lists every class on the host cluster, including
classes your vcluster may not use. LPP classes show the provisioner
`local-path-provisioner.local/<class>`. This guide covers only the families above: ask the
platform team (s3df-help) before you use any other class. [Checking](#checking) shows the share
root of a bound claim.

## Claim settings

| Field | Value | What it is for |
|---|---|---|
| `storageClassName` | A class from the table above, for example `sdf-group-ad` | Chooses the share |
| `accessModes` | `[ReadWriteMany]`, exactly | The only mode the LPP classes support |
| `resources.requests.storage` | Any size, for example `1Gi` | Required, but not enforced |

Two settings on the pod's `volumeMounts` control what the pod sees:

| Field | What it does |
|---|---|
| `readOnly: true` | The pod cannot write to the share. This is the way to get read-only access; keep the claim `ReadWriteMany` |
| `subPath: <dir>` | Mounts a directory of the share, relative to the share root, instead of the root. The kubelet creates the directory if it is missing. Other claims still see the whole share |

## Deleting a claim

The classes have reclaim policy `Delete`, but deleting a claim never deletes data on the share. It
removes only the Kubernetes objects, the claim and its PV. Files are deleted only if your
application deletes them through its mount.

To use the share again, apply the claim from your own manifest. Don't re-create it from
`kubectl get pvc -o yaml` output: that carries `volumeName` and binding annotations for the
deleted PV.

## Examples

| File | What it shows |
|---|---|
| [`pvc.yaml`](pvc.yaml) | A claim on `/sdf/group/ad` |
| [`pod.yaml`](pod.yaml) | A pod with the whole share, read-write |
| [`pod-read-only.yaml`](pod-read-only.yaml) | nginx serving one directory of the share, read-only |
| [`deployment-subpath.yaml`](deployment-subpath.yaml) | A Deployment whose replicas share one subdirectory, read-write |

The manifests set no namespace. Apply them to a namespace of your own with `-n`: platform policy
forbids the vcluster's `default` namespace, and [Your vcluster](../../vcluster/README.md) shows how
to create one. The pods in all three workload examples use the claim from `pvc.yaml`.

```bash
kubectl apply -n my-namespace -f pvc.yaml -f pod.yaml
kubectl get pvc task-pv-claim -n my-namespace   # Pending until the pod is scheduled, then Bound
kubectl logs task-pv-pod -n my-namespace        # the top level of /sdf/group/ad

# Removes the pod, the claim and its PV. The files on the share stay.
kubectl delete -n my-namespace --ignore-not-found -f pod.yaml -f pvc.yaml
```

`task-pv-pod` exits once it has listed the share. The platform deletes finished pods 10 to 25
minutes after they are created, so read the log soon; see
[Jobs and CronJobs](../../jobs/README.md).

## Mistakes that break a claim or risk the data

| Mistake | Result |
|---|---|
| `ReadWriteOnce` or `ReadWriteOncePod` | Not supported. Some classes reject the claim today; others bind it to the whole share, so a workload that expects a private, empty volume gets facility data |
| `ReadOnlyMany` to get read-only access | Not supported. The access mode does not stop a pod from writing to the share; only `readOnly: true` on the volumeMount does |
| `sdf-home` or `sdf-scratch` mounted at the root, read-write | The pod can write to any user's files that the file permissions allow. Mount only the directory you need with `subPath`, and add `readOnly: true` if the pod only reads |
| A `nodeSelector` or node affinity for storage | Not needed: the PV already places the pod. A selector that matches no node with the storage label leaves the pod `Pending` |
| A misspelt `subPath` | The kubelet creates a new, empty directory on the share, and the pod starts without an error |
| Changing the reclaim policy of the PV, or patching it in any other way | `Recycle` makes Kubernetes delete the share's contents when the claim is released. Never set it, and don't edit LPP PVs |
| A class that is not on your vcluster's allowlist | The host cluster (Kyverno) rejects the synced claim, so it never binds. Ask the platform team (s3df-help) |
| No pod uses the claim | The claim stays `Pending`. This is expected |

A new pod's first scheduling attempt can fail before it starts: if the scheduler first picks a
node without the storage label, the pod is placed again, on a node that has it.

## Checking

```bash
# Every class on the host cluster. Your vcluster can use only the ones on its allowlist.
kubectl get storageclass

# The share root behind a bound claim. The PV in your vcluster mirrors the one on the host.
kubectl get pv "$(kubectl get pvc task-pv-claim -n my-namespace -o jsonpath='{.spec.volumeName}')" \
  -o jsonpath='{.spec.hostPath.path}{"\n"}'

# Why a claim or a pod is waiting: read the events at the end.
kubectl describe pvc task-pv-claim -n my-namespace
kubectl describe pod task-pv-pod -n my-namespace
```

A pod that stays in `ContainerCreating` with a `FailedMount` event naming the share root runs on a
node where the share is missing. Report the pod and the event to the platform team (s3df-help).

Upstream reference: [Local Path Provisioner](https://github.com/rancher/local-path-provisioner)
and [Kubernetes persistent volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/).
S3DF runs its own build of LPP, which always serves the share root and never deletes data.
