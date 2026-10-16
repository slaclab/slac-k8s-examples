# slac-k8s-template-app
SLAC Kubernetes (K8s) app deployment template

## Description

This repo is intended to provide workable examples and best practices for deploying various workloads on SLAC Kubernetes clusters.

## Goals

The example manifests provided in this repo should be able to be adapted by developers to get their application running on the SLAC Kubernetes infrastructure. These examples will be updated as new best practices and technologies are introduced (e.g., new operators, new storage etc).

## Guides

Each guide is a README with example manifests next to it. It explains how a platform feature works,
why the platform does it that way, and how to use it from inside your vcluster. Start with
[Your vcluster](basic/vcluster/README.md): many features depend on a switch or allowlist that the
platform team sets for your vcluster.

### Your vcluster

| Guide | What it covers |
|---|---|
| [Your vcluster](basic/vcluster/README.md) | What a vcluster is, what syncs to the host cluster, feature switches, namespaces, backups |
| [Logging in and access](basic/vcluster/access/README.md) | Logging in through gangway and Dex, kubeconfig, giving teammates access with RBAC |
| [Platform policies](basic/platform-policies/README.md) | What the host cluster rejects, changes or deletes, and why |

### Networking

| Guide | What it covers |
|---|---|
| [Getting traffic in and out](basic/networking/README.md) | Choosing between HTTPRoute, Ingress and LoadBalancer Services; outbound traffic |
| [HTTPRoutes with S3DF login](basic/httproutes/README.md) | Publishing a web application on the gateway, with or without the S3DF login |
| [Middlewares for HTTPRoutes](basic/httproutes/middlewares/README.md) | Path rewrites, headers, IP allowlists and rate limits on an HTTPRoute |
| [Ingress](basic/ingresses/README.md) | The legacy ingress-nginx path, hostnames, and moving to an HTTPRoute |
| [LoadBalancer Services](basic/services/README.md) | Non-HTTP services on MetalLB address pools, source ranges |
| [Network policies](basic/networking/network-policies/README.md) | Network isolation for your vcluster and NetworkPolicies |
| [DNS](basic/networking/dns/README.md) | How names resolve inside a vcluster |
| [Logging users in to your application](basic/authentication/README.md) | s3df-authnz or your own OIDC client in S3DF Dex |

### Storage

| Guide | What it covers |
|---|---|
| [Choosing a StorageClass](basic/storage/README.md) | The storage families, the per-vcluster allowlist, what is and is not backed up |
| [Weka volumes](basic/storage/weka/README.md) | New, empty persistent volumes for your application (the default class) |
| [S3DF filesystems](basic/storage/sdf-filesystem/README.md) | Mounting an existing facility share such as `/sdf/group/<facility>` |
| [Node-local ZFS volumes](basic/storage/node-local-zfs/README.md) | Fast volumes on dedicated node pools, and their trade-offs |

### Secrets and certificates

| Guide | What it covers |
|---|---|
| [Secrets in your vcluster](basic/secrets/README.md) | The ways to get secrets from Vault into a vcluster, and which to choose |
| [External Secrets](basic/secrets/external-secrets/README.md) | ExternalSecrets that keep a Kubernetes Secret in sync with Vault |
| [vault-secrets-operator](basic/secrets/vault-secrets-operator/README.md) | VaultSecrets, in vclusters where this operator is installed |
| [Secrets at deploy time](basic/secrets/from-vault/README.md) | A Makefile and kustomize secretGenerator that read Vault when you apply |
| [TLS certificates](basic/certificates/README.md) | cert-manager Issuers and Certificates for in-cluster TLS |

### Monitoring and logs

| Guide | What it covers |
|---|---|
| [Monitoring](basic/monitoring/README.md) | Where your metrics go, how they are scraped, where to look at them |
| [ServiceMonitor and PodMonitor](basic/serviceMonitor/README.md) | Telling the platform Prometheus to scrape your application |
| [Logs and events](basic/logging/README.md) | Container logs and Kubernetes events, including after a pod is gone |
| [Autoscaling](basic/autoscaling/README.md) | `kubectl top` and HorizontalPodAutoscalers |

### Compute and scheduling

| Guide | What it covers |
|---|---|
| [Requests and limits](basic/resources/README.md) | Requests, limits, QoS classes and ephemeral storage, and why to set them |
| [Node placement](basic/scheduling/README.md) | Node pools, taints, the tolerations the platform adds, node labels |
| [Disruptions and availability](basic/scheduling/disruptions/README.md) | Evictions, node failures, preemption and running highly available |
| [Jobs and CronJobs](basic/jobs/README.md) | What happens to finished pods, and Job settings that work here |
| [GPU workloads](basic/gpu/README.md) | Requesting GPUs and checking what your pod got |
| [Container images](basic/images/README.md) | How images are pulled, pinning, private registries |

### Operators and databases

| Guide | What it covers |
|---|---|
| [Operators in your vcluster](operators/README.md) | The model every operator guide follows: you install and upgrade the operator |
| [PostgreSQL (CloudNativePG)](operators/cloudnativepg/README.md) | Installing the operator, a database cluster, connections and monitoring |
| [PostgreSQL backups](operators/cloudnativepg/backups/README.md) | Backups to S3, scheduled backups, restore and point-in-time recovery |
| [MariaDB](operators/mariadb-operator/README.md) | MariaDB with mariadb-operator |
| [MongoDB](operators/percona/README.md) | MongoDB with the Percona operator |
| [Kafka](operators/strimzi/README.md) | Kafka with Strimzi |

### Advanced and worked examples

| Guide | What it covers |
|---|---|
| [Secondary networks (Multus)](advanced/multus-secondary-networks/README.md) | A second interface on an ingest or DMZ network, with a fixed address |
| [Fixed-address egress through socat](advanced/outgoing-ingest-network-with-socat-proxy/README.md) | Reaching an outside service from one fixed address |
| [GitOps with Argo CD](advanced/gitops-argocd/README.md) | Deploying into your vcluster from Git |
| [PostgreSQL example database](kubernetes/overlays/dev/cnpg-example-database/README.md) | A CloudNativePG cluster with credentials from Vault, as a kustomize overlay |
| [GPU example application](kubernetes/overlays/dev/gpu-example-app/README.md) | A GPU Deployment as a kustomize overlay |
| [EPICS example](kubernetes/overlays/dev/epics-example-app/README.md) | An EPICS workload on a secondary network |

## Prerequisites

We assume a famility with the common kubernetes objects (Pods, Deployments, Statefulsets, PVCs, PVs, Services and Ingresses). Some familarity with commom Unix tools is also expected.

## Manifest Organisation

To our benefit, the kubernetes platform is driven by declarative configuration based configuration files (often in YAML). However, there is a bewildering array of differing methodologies and techniques to the storage, organisation and deployment of a kubernetes 'application' that is collectively known as the 'manifest'. We describe how we organise and access these files in order to help understand how these 'manifests' relate to real application deployments.

### YAML Files

Whilst is is possible to 'house' multiple YAML files within a single YAML configuration file (delimited by `---`) we generally would advise against it, especially for longer or more complicated manifests. By separating each kubernetes object into their own configuration file, it is often easier to track and thus understand the application as a whole.

### Kustomize

In order to tie together the separate YAML configuration files (kinda like an entrypoint to the application), we use the built in (Kubernetes native) [Kustomize](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/) tool. By organising all your separate YAML configuration files under kustomize, we fully embrace the declarative, self-documenting and revision control of declarative infrastructure. 

We also utilize the [Kustomize base/overlay model](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/#bases-and-overlays) for hierarchical/inherited deployments, which enable easier management of multiple deployments with common configurations, e.g.:

```
<application_root>
   \__ kubernetes
     |__ overlays
       \__ dev/kustomization.yaml    # (May inherit and override configurations from ../../base/kustomization.yaml)
       |__ stage/kustomization.yaml  # "
       |__ prod/kustomization.yaml   # "
```

We generally do not recommend the use of `base` overlays (from which the separate environments commonly inherit configuration from) since we have found that it can make changes in one environment's overlay tightly coupled with other environments. We would recommend simply using `diff` and `cp` tools to more simply duplicate and determine differences between different environments.

### Makefile

We often need to bring in from external project repos, helm charts, or secrets into our kubernetes environments. We explicitly declare such imports in Makefile targets. This is done to normalize our deployments and bring all Kubernetes configuration management under Kustomize control. Make targets are also defined such that they consolidate and simplify updating and applying changes to deployments.

We do not recommend hardcoding any sensitive information within your (often public) manifests. Whilst kubernetes provides Secrets and ConfigMaps to abstract this information, it is still necessary to populate such objects in a kubernetes deployment. Generation and updating such resources (Secrets, ConfigMaps, etc.) from external (to the manifests) is recommended. This will often involve pulling secrets in from a Hashicorp Vault instance. However, to best abstract how this is done from the manifests itself, we make use of Makefile targets that will (temporalily) pull in such secrets to local disk before using Kustomize `secretGenerators` to automagicially populate and revision control this sensitive data. Since failure to gather this information will also prevent an update (and rollout) of the kubernetes components, this is also a nice way to ensure that only those with access to the sensitive information can even modify the running configuration of the application(s).

In addition, by standardizing on certain task names like `apply`, `secrets`, `dump` etc, the user has a consistent way of determining how the entire kubernete'd environment is ran - ie a common entrypoint is well defined for all applications. This can save a considerable amount of time when someone else has to troubleshoot an issue with your application.

## Helm

A popular tool to help package the deployment of common applications is Helm. Helm, at its heart is a templating system from which you can derive new templates from 'values' YAML files. Whilst this is somewhat declarative, it can be prone to the whims of the helm template developer wrt revision control and what (kubernetes) templates can and are actually generated. We often find that many helm templates lack sophisticated methods of modifying common required kubernetes objects (such as overriding Ingress paths, or declaring a different storageClass etc). These latter issues should not be overstated since quite often you may have to wait a long time for the helm developer to acknowledge and/or merge your feature request. My personal take is that helm is often duplicative to what kustomize can and does do. Kustomize also has an extensive patch capability where there is no need to wait for upstream code changes to be made to modify these templates to your needs.

However, there exists a vast catalog of helm 'charts'. And rather than forcing everyone to use native YAML configuration files, we make use of Makefiles and kustomize to 'import' and lock helm templates into the kubernetes manifest. This allows us to make use of already available charts, utilise the power of kustomize to modify what is needed, and most importantly lock in the version of helm specified software to our repo so that there are no external dependencies that may break.

### Operators

We utilize the [Kubernetes operator pattern](https://kubernetes.io/docs/concepts/extend-kubernetes/operator/) when possible to automate tasks and streamline deployments. Several examples of off-the-shelf operators for common applications are provided: database administration (Postgres, MySQL, MongoDB), event/message streaming (Kafka). These operators are deployed by downloading/extracting their manifests via `curl` or `helm` and managed by `Kustomize`. You install and upgrade them inside your own vcluster; see [Operators in your vcluster](operators/README.md).

### Secrets

[Kubernetes Secrets](https://kubernetes.io/docs/concepts/configuration/secret/) are stored in a [Hashicorp Vault](https://developer.hashicorp.com/vault/docs/what-is-vault) instance and passed via `make` to `Kustomize`'s [secretGenerator](https://kubernetes.io/docs/tasks/configmap-secret/managing-secret-using-kustomize/#create-the-kustomization-file), which creates the appropriate Kubernetes Secret objects when applied. The secrets are then available to be consumed by other Kubernetes objects. This is one of several ways to get a secret from Vault into a vcluster; External Secrets keeps the Secret in sync with Vault instead. See [Secrets in your vcluster](basic/secrets/README.md) for the options and which to choose.
