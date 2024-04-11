# slac-k8s-template-app
SLAC Kubernetes (K8s) app deployment template

## Description

This repo is intended to provide workable examples and best practices for deploying various workloads on SLAC Kubernetes clusters.

## Goals

The example manifests provided in this repo should be able to be adapted by developers to get their application running on the SLAC Kubernetes infrastructure. These examples will be updated as new best practices and technologies are introduced (e.g., new operators, new storage etc).

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

We utilize the [Kubernetes operator pattern](https://kubernetes.io/docs/concepts/extend-kubernetes/operator/) when possible to automate tasks and streamline deployments. Several examples of off-the-shelf operators for common applications are provided: database administration (Postgres, MySQL, MongoDB), event/message streaming (Kafka). These operators are deployed by downloading/extracting their manifests via `curl` or `helm` and managed by `Kustomize`.

### Secrets

[Kubernetes Secrets](https://kubernetes.io/docs/concepts/configuration/secret/) are stored in a [Hashicorp Vault](https://developer.hashicorp.com/vault/docs/what-is-vault) instance and passed via `make` to `Kustomize`'s [secretGenerator](https://kubernetes.io/docs/tasks/configmap-secret/managing-secret-using-kustomize/#create-the-kustomization-file), which creates the appropriate Kubernetes Secret objects when applied. The secrets are then available to be consumed by other Kubernetes objects.
