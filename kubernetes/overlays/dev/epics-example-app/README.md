# EPICS Example Workload

## Description
The manifests in this directory contain examples for how to deploy EPICS client/server workloads in the S3DF Kubernetes environment.

## Background
SLAC Accelerator Directorate (AD) uses the EPICS controls system to communicate with and control devices on the various accelerators at SLAC.
EPICS controls systems use two communication protocols:
- Channel Access (CA): used to communicate with legacy devices running EPICS v3.14 or earlier
- PV Access (PVA): used to communicate with devices running EPICS v3.15 or later
Note: some devices may utilize both protocols.

The accelerator production devices reside on a firewalled network, separate from the subnet that S3DF and its various systems reside on.
To facilitate communication between hosts on these networks the following have been deployed: 

- Layer 2 trunking with so-called "ingest" networks to allow direct networking between hosts in both VLANs.
- S3DF Kubernetes uses the Multus Container Networking Interface (CNI) to allow multi-homing of Kubernetes pods, e.g. pods with multiple 
networking interfaces. By implementing a Multus network specification, a workload running in S3DF Kubernetes can deploy pods that can 
communicate with hosts outside of its default container network utilizing a bridged connection on the node where the pod is running. 

## Prerequisites
EPICS workloads in S3DF Kubernetes require:
- An S3DF Kubernetes vCluster with pre-approved access to the applicable ingest network (controlled via Kyverno policy)
- A Multus network definition of the IP address pool on the applicable ingest network
- An EPICS application in a container image, uploaded to a container repository such as DockerHub, GHCR, GitLab Container Repository, Quay.io, etc.
- The appropriate EPICS environment settings available for the application (e.g., EPICS-specific environment variables that are loaded into the pod 
at the time of deployment to make them available in the container, such as via a mounted Kubernetes ConfigMap resource. See: `epics-config.env`)

## Procedure
1. Request a S3DF Kubernetes vCluster for your workload with access to the appropriate ingest network.
2. Upon approval of (1), request a static IP(s) in the Multus network IP address pool, which will be provided by SCS-AUS admins.
3. Deploy your EPICS workload with the appropriate Multus annotation for network name and static IP address acquired in steps 
(1) and (2):
```
[...]
    metadata:
      annotations:
        k8s.v1.cni.cncf.io/networks: '[
                { 
                  "name": "multus-static-ip-pool", # name of Multus networkAttachmentDefinition
                  "namespace": "multus-system",
                  "ips": [ "192.168.1.10/24" ], # static IP provisioned from Multus IP pool
                  "gateway": [ "192.168.0.1" ] # default network gateway
                }
          ]'
[...]
```
See `epics-test.yaml` for more details on how to configure the Multus annotation.
