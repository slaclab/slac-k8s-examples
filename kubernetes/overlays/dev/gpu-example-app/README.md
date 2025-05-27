# gpu-example-app
Example deployment of GPU-aware pods in S3DF Kubernetes

## Description

The example manifests provided in this directory demonstrate how developers can deploy applications with NVIDIA GPU resources running on S3DF Kubernetes infrastructure. For further examples, see the official NVIDIA gpu-operator documentation: [Running Sample GPU Applications](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/getting-started.html#verification-running-sample-gpu-applications)

## Verification

After these manifests have been applied, scheduled, and running on S3DF K8s GPU worker nodes, the following can be used to verify that the pods can access the requested NVIDIA GPU resources:

```
$ kubectl -n gpu-example-app exec -ti gpu-example-app-<hash> -- nvidia-debugdump -l
Found 1 NVIDIA devices
    Device ID:              0
    Device name:            NVIDIA GeForce GTX 1080 Ti
    GPU internal ID:        GPU-<uuid>

$ kubectl -n gpu-example-app exec -ti gpu-example-app-<hash> -- /bin/sh -c cuda-samples/vectorAdd
[Vector addition of 50000 elements]
Copy input data from the host memory to the CUDA device
CUDA kernel launch with 196 blocks of 256 threads
Copy output data from the CUDA device to the host memory
Test PASSED
Done
```

## Notes
Workloads running on S3DF Kubernetes GPU worker nodes that require access to Weka storage (e.g., pods that read data stored in S3DF filesystem paths under `/sdf/data/<facility>/...`) must define the appropriate storageClassName in their PersistentVolumeClaim. If the required path is not currently provisioned by an existing S3DF K8s storageClass, please submit a request for a new storageClass to: [S3DF-Help](emailto:s3df-help@slac.stanford.edu) and include the relevant details such as the path, access justification, etc.
