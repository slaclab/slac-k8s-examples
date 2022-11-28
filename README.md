# slac-k8s-template-app
SLAC Kubernetes (K8s) app deployment template

## Description
This repo is intended to provide examples and best practices for deploying various workloads on SLAC Kubernetes clusters.

## Goals
The example manifests provided in this repo can be customized by developers to get their application running on SLAC Kubernetes infrastructure. These examples will be updated as new best practices and technologies are introduced (e.g., new operators).

## SLAC Kubernetes Deployments

Below is an overview of a typical workload deployment on SLAC K8s infrastructure.

### make
Generation and updating of manifests and K8s resources (Secrets, ConfigMaps, etc.) from external project repos, helm charts, or secrets databases are managed via Makefile targets. This is done to normalize our deployments and bring all Kubernetes configuration management under Kustomize control. Make targets are also defined such that they consolidate and simplify updating and applying changes to deployments.

### Kustomize
Configuration management is handled by the Kubernetes-native [Kustomize](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/) tool. Using this tool allows all aspects of a K8s deployment to be configured in a declarative, self-documenting manner, including off-the-shelf components like operators and helm charts (see below) via kustomization manifests. We also utilize the [Kustomize base/overlay model](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/#bases-and-overlays) for hierarchical/inherited deployments, which enable easier management of multiple deployments with common configurations, e.g.:

```
<application_root>
   \__ kubernetes
     \__ base/kustomization.yaml
     |__ overlays
       \__ dev/kustomization.yaml    # inherit and override configurations from base/kustomization.yaml
       |__ stage/kustomization.yaml  # "
       |__ prod/kustomization.yaml   # "
```

### Operators
We utilize the [Kubernetes operator pattern](https://kubernetes.io/docs/concepts/extend-kubernetes/operator/) when possible to automate tasks and streamline deployments. Several examples of off-the-shelf operators for common applications are provided: database administration (Postgres, MySQL, MongoDB), event/message streaming (Kafka). These operators are deployed by downloading/extracting their manifests via `curl` or `helm` and managed by `Kustomize`.

### Secrets
[Kubernetes Secrets](https://kubernetes.io/docs/concepts/configuration/secret/) are stored in a [Hashicorp Vault](https://developer.hashicorp.com/vault/docs/what-is-vault) instance and passed via `make` to `Kustomize`'s [secretGenerator](https://kubernetes.io/docs/tasks/configmap-secret/managing-secret-using-kustomize/#create-the-kustomization-file), which creates the appropriate Kubernetes Secret objects when applied. The secrets are then available to be consumed by other Kubernetes objects.
