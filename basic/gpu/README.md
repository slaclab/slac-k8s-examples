# GPU workloads (NVIDIA device plugin)

A container asks for NVIDIA GPUs with the extended resource `nvidia.com/gpu` in its `limits`. The
host scheduler then runs the pod on a GPU node, and the NVIDIA device plugin gives the container
whole GPUs for its own use. Use GPUs for CUDA work such as training, inference and image
reconstruction. GPU nodes are few and shared by every vcluster, so hold GPUs only while you use
them. Requesting GPUs needs no per-vcluster switch. Run the [check Job](#checking) once before you
rely on a GPU: it shows whether a container in your vcluster can use one.

## How a GPU pod reaches a GPU

Write the pod, or the Deployment or Job that creates it, with a `nvidia.com/gpu` limit and without
tolerations. The platform does the rest:

1. The vcluster syncs the pod to the host cluster.
2. If a container in `containers` has a `nvidia.com/gpu` limit, Kyverno on the host adds the
   toleration `{key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}`, unless the pod
   already has a toleration with that key.
3. The host scheduler places the pod on a GPU node with enough free GPUs, CPU and memory. Until a
   node has them, the pod stays `Pending`.
4. The NVIDIA device plugin on that node assigns whole GPUs to the container. They stay assigned
   until the pod ends, whether the container uses them or not.
5. The container starts with the GPU devices it was given. The driver libraries and `nvidia-smi`
   come from the node, not from your image.

GPU nodes carry an `nvidia.com/gpu` taint (`NoSchedule`), which keeps pods that need no GPU off the
scarce GPU nodes. The host tolerates the taint for every pod that asks for a GPU, so the GPU limit
is all you write. [Node placement](../scheduling/README.md#gpu-pods) explains the taints of the
other node pools.

## What to set

| Field | Value | What it is for |
|---|---|---|
| `resources.limits."nvidia.com/gpu"`, on a container in `containers` | A whole number, for example `1` | The number of GPUs for this container. Kubernetes sets the request to the same number |
| `resources.requests."nvidia.com/gpu"` | Leave it out, or the same number as the limit | Kubernetes rejects a GPU request without a limit, or one that differs from the limit |
| `resources` for `cpu` and `memory` | Requests and limits sized to the work | The GPU pods on a node share its CPUs and memory. See [Requests and limits](../resources/README.md) |
| `tolerations` | None for GPUs | The host adds the GPU toleration |
| `runtimeClassName` | Leave it unset | RuntimeClasses are not synced from the host into your vcluster |
| `strategy.type`, in a Deployment | `Recreate` | The default rolling update starts the new pod before it stops the old one, so it needs a free GPU beyond the ones the Deployment holds. `Recreate` stops the old pod first, at the cost of a short gap |

## Whole GPUs only

- The platform does not split or share GPUs: there is no MIG, time-slicing or MPS. Each GPU
  belongs to one container, and the limit must be a whole number.
- Containers do not share GPUs, even in one pod. Put the limit on the container that runs the GPU
  code.
- All the GPUs of a pod come from one node. A pod that asks for more GPUs than any node has free
  stays `Pending`.

## The GPU, its driver and your image

The NVIDIA driver is installed on the GPU nodes, not in your image, so that one driver matches the
node's kernel and GPUs. Use an image that brings the CUDA libraries your code needs, without a
driver, and check two things:

- **CUDA version.** The image's CUDA version should be no newer than the one the node's driver
  supports. NVIDIA's [CUDA compatibility](https://docs.nvidia.com/deploy/cuda-compatibility/)
  guide lists the exceptions.
- **Compute capability.** The image's GPU code must be built for the GPU's compute capability.
  Framework releases drop old compute capabilities, so compare the GPU's with the framework's list
  before you choose a version.

GPU Feature Discovery labels each GPU node with its hardware and driver. Your vcluster shows the
nodes your pods run on with their real labels (see
[What your vcluster shows](../scheduling/README.md#what-your-vcluster-shows)), and
[Checking](#checking) reads them:

| Label | What it means |
|---|---|
| `nvidia.com/gpu.product` | The GPU model, with `-` in place of spaces |
| `nvidia.com/gpu.memory` | Memory per GPU, in MiB |
| `nvidia.com/gpu.count` | The number of GPUs on the node |
| `nvidia.com/gpu.compute.major`, `nvidia.com/gpu.compute.minor` | The compute capability, for example `8` and `0` for 8.0 |
| `nvidia.com/cuda.driver-version.full` | The driver version |
| `nvidia.com/cuda.runtime-version.full` | The newest CUDA version the driver supports |

`nvidia-smi` in the container shows the same: the driver version and `CUDA Version` in its
header, and the model and memory of each GPU the container got. The GPU hardware changes over
time, so read these values from the node or from `nvidia-smi`, not from a document.

### Choosing a GPU model

Most workloads need no selector. When yours needs a particular GPU model, add a `nodeSelector` on
the model's label:

```yaml
      nodeSelector:
        nvidia.com/gpu.product: <the model's nvidia.com/gpu.product value>
```

A selector that matches no GPU node leaves the pod `Pending`, and a selector on a model with few
GPUs makes it wait longer. Ask the platform team (s3df-help) which GPU models the cluster has.

## GPUs are scarce

Every vcluster uses the same few GPUs. The platform sets no GPU quota, and tenant pods do not
preempt each other (see [Priority classes](../scheduling/README.md#priority-classes)), so GPUs go
to the pods scheduled first, and each pod keeps its GPUs until it ends.

- Run batch work as a Job: its pod ends when the work is done, and its GPUs go back. Set
  `activeDeadlineSeconds`, so a stuck run does not hold them. See
  [Jobs and CronJobs](../jobs/README.md).
- Scale a Deployment to zero replicas while nobody uses it:
  `kubectl scale deployment/my-app -n my-namespace --replicas=0`.
- Ask for the GPUs your code uses. `nvidia-smi` shows how busy each GPU of the container is.
- Delete test pods and Deployments when you are done.

## Data for GPU pods

A GPU pod mounts claims like any other pod. To read data that already exists under
`/sdf/data/<facility>`, use a claim in the facility's class `sdf-data-<facility>`: see
[S3DF filesystems](../storage/sdf-filesystem/README.md). For a new, empty volume of your own, use
`wekafs--sdf-k8s01`: see [Weka volumes](../storage/weka/README.md). The class must be on your
vcluster's StorageClass allowlist (see [Your vcluster](../vcluster/README.md)). An S3DF filesystem
volume can be used only on nodes that carry its share's storage label. If a GPU pod with such a
claim stays `Pending` with `volume node affinity conflict` in its events, ask the platform team
(s3df-help).

## Examples

| File | What it shows |
|---|---|
| [`job-cuda-vectoradd.yaml`](job-cuda-vectoradd.yaml) | A Job with one GPU that prints `nvidia-smi` and runs NVIDIA's CUDA vectorAdd sample, to check that a container can use its GPU |

For a single-replica GPU Deployment with `strategy: Recreate`, as a kustomize overlay, see
[gpu-example-app](../../kubernetes/overlays/dev/gpu-example-app/README.md).

The manifests set no namespace. Apply them to a namespace of your own with `-n`: platform policy
forbids the vcluster's `default` namespace, and [Your vcluster](../vcluster/README.md) shows how to
create one.

## Mistakes that strand a GPU pod or waste GPUs

| Mistake | Result |
|---|---|
| `nvidia.com/gpu` in `requests` only | Kubernetes rejects the manifest: a GPU needs a limit |
| A fractional GPU, such as `0.5` | Kubernetes rejects the manifest: GPUs come whole |
| A GPU limit only on an initContainer | The host adds no GPU toleration, and the pod stays `Pending` with an untolerated `nvidia.com/gpu` taint |
| A toleration with `operator: Exists` and no `key` | Tolerates every taint: the pod can land on reserved nodes, and is never moved off a failed node. See [Never tolerate every taint](../scheduling/README.md#never-tolerate-every-taint) |
| A GPU toleration written by hand on a pod without a GPU limit | The pod can land on a GPU node without getting a GPU, and takes CPU and memory that GPU pods need |
| `runtimeClassName: nvidia`, as in some upstream examples and Helm charts | Your vcluster has no RuntimeClass of that name, so its API server rejects the pod |
| A GPU Deployment with the default rolling update | A rollout needs one more free GPU. While none is free, the new pod stays `Pending` and the rollout does not finish. Use `strategy: Recreate` |
| An image built for a newer CUDA version than the driver supports, outside NVIDIA's compatibility rules | CUDA does not start: `CUDA driver version is insufficient for CUDA runtime version` |
| An image or framework build without the GPU's compute capability | GPU code fails with `no kernel image is available for execution on the device` |
| A GPU pod left running after the work is done | Its GPUs stay assigned, and other GPU pods wait |
| A claim in `wekafs--sdf-k8s01` to read `/sdf/data/<facility>` | The claim is a new, empty volume, not the share. Use `sdf-data-<facility>` |

## Checking

```bash
kubectl apply -n my-namespace -f job-cuda-vectoradd.yaml

# Where the pod runs. NODE is <none> while it waits for a GPU.
kubectl get pods -n my-namespace -l batch.kubernetes.io/job-name=my-app-gpu-check -o wide

# Why it waits: "Insufficient nvidia.com/gpu" means no GPU node has enough free GPUs now.
POD=$(kubectl get pods -n my-namespace -l batch.kubernetes.io/job-name=my-app-gpu-check -o name | head -n 1)
kubectl describe -n my-namespace "$POD" | sed -n '/^Events:/,$p'

# COMPLETIONS 1/1 when the GPU works. The Job fails if vectorAdd cannot use the GPU.
kubectl get job -n my-namespace my-app-gpu-check

# The nvidia-smi table, then "Test PASSED". Read it soon: the platform deletes finished pods,
# with their logs, within minutes.
kubectl logs -n my-namespace job/my-app-gpu-check

# The GPU labels of the node the pod ran on.
NODE=$(kubectl get -n my-namespace "$POD" -o jsonpath='{.spec.nodeName}')
kubectl get node "$NODE" -L nvidia.com/gpu.product,nvidia.com/gpu.memory,nvidia.com/gpu.count,nvidia.com/gpu.compute.major,nvidia.com/gpu.compute.minor,nvidia.com/cuda.driver-version.full,nvidia.com/cuda.runtime-version.full

# The same for a running GPU pod of your own.
kubectl exec -n my-namespace deploy/my-app -- nvidia-smi
```

The container did not get a working GPU if the Job fails, or the log shows any of these:

- `nvidia-smi: not found`: the driver tools were not added to the container.
- A CUDA error from vectorAdd instead of `Test PASSED`, such as `no CUDA-capable device is detected`.

Then ask the platform team (s3df-help), and include the log and the node name. For why finished pods disappear, see
[Jobs and CronJobs](../jobs/README.md).

Reference:
[scheduling GPUs in Kubernetes](https://kubernetes.io/docs/tasks/manage-gpus/scheduling-gpus/),
[CUDA compatibility](https://docs.nvidia.com/deploy/cuda-compatibility/),
and [compute capabilities of NVIDIA GPUs](https://developer.nvidia.com/cuda-gpus).
