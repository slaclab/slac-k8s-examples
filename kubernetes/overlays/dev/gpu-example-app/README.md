# GPU example application (kustomize)

A Deployment that holds one NVIDIA GPU, for checking GPU access from a shell in the container. Read [GPU workloads](../../../../basic/gpu/README.md)
first: it explains how GPU pods work on S3DF, what to set, and how to choose an image.

## Files

| File | What it is |
|---|---|
| [`kustomization.yaml`](kustomization.yaml) | Lists the Deployment. It sets no namespace: you pass one with `-n` |
| [`gpu-example-app.yaml`](gpu-example-app.yaml) | The Deployment: one replica, one GPU in `limits`, `strategy: Recreate`, and no tolerations. Its container runs NVIDIA's CUDA vectorAdd sample image and sleeps, so you can run commands in it |
| [`Makefile`](Makefile) | `make apply` and `make delete`, into `NAMESPACE` (default `my-namespace`) |

The Deployment sets no tolerations: the host adds the GPU toleration to every pod with a
`nvidia.com/gpu` limit. It uses `strategy: Recreate` because a rolling update would need a second
free GPU.

## Deploying and checking

Run the commands from this directory. Use a namespace of your own: platform policy forbids the
vcluster's `default` namespace, and [Your vcluster](../../../../basic/vcluster/README.md) shows how
to create one.

```bash
kubectl apply -k . -n my-namespace        # or: make apply NAMESPACE=my-namespace

# NODE is <none> while the pod waits for a free GPU; describe the pod to see why.
kubectl get pods -n my-namespace -o wide

# The GPU the container got, with the driver version and the newest CUDA version it supports.
kubectl exec -n my-namespace deploy/gpu-example-app -- nvidia-smi

# A CUDA program on the GPU.
kubectl exec -n my-namespace deploy/gpu-example-app -- /cuda-samples/vectorAdd
```

If `nvidia-smi` is not found, or vectorAdd prints a CUDA error, the container did not get a working
GPU: see [Checking](../../../../basic/gpu/README.md#checking). On success the last command prints:

```
[Vector addition of 50000 elements]
Copy input data from the host memory to the CUDA device
CUDA kernel launch with 196 blocks of 256 threads
Copy output data from the CUDA device to the host memory
Test PASSED
Done
```

## Freeing the GPU

The pod holds its GPU for as long as it exists, even while it only sleeps, and GPUs are few and
shared by every vcluster. Delete the example when you are done:

```bash
kubectl delete -k . -n my-namespace       # or: make delete NAMESPACE=my-namespace
```

## Reading S3DF data from a GPU pod

To read data under `/sdf/data/<facility>`, mount a claim in the facility's class
`sdf-data-<facility>`: see [S3DF filesystems](../../../../basic/storage/sdf-filesystem/README.md).
The class `wekafs--sdf-k8s01` creates a new, empty volume instead, and does not reach
`/sdf/data`. Your vcluster can use only the classes on its allowlist; ask the platform team
([s3df-help](mailto:s3df-help@slac.stanford.edu)) to add the one you need.

For more examples, see NVIDIA's
[sample GPU applications](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/getting-started.html#verification-running-sample-gpu-applications).
