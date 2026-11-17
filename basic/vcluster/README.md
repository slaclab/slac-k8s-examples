# Your tenant environment (vcluster)

A vcluster is your own Kubernetes cluster on the S3DF Kubernetes platform. It has its own API
server and etcd, and you are cluster-admin in it: you create namespaces and install CRDs, operators
and Helm charts without any rights on the shared host cluster. Its pods run on the host cluster's
nodes, in one host namespace, `vcluster--<name>`. Read this guide first: it says what reaches the
host, which features the platform turns on for each vcluster, and what is backed up.

To log in and to see who may do what, read [Logging in to your vcluster](access/README.md).

## How your vcluster works

1. You work only with your vcluster's API server, through `kubectl`. Every object you create is
   stored in your vcluster's own etcd.
2. Controllers inside your vcluster run your Deployments, StatefulSets, Jobs and operators, as in
   any cluster.
3. The vcluster's syncer copies the objects the host must run, such as pods, Services and
   PersistentVolumeClaims, into `vcluster--<name>` on the host cluster, under new names.
4. The host cluster's scheduler places your pods on shared nodes. Host policies check the synced
   objects first: see [Platform policies](../platform-policies/README.md).
5. Pod status and host events come back to your objects, so `kubectl get` and `kubectl describe`
   in your vcluster show what happened on the host.

The vcluster syncs only what the host must run, and puts all of it into one host namespace, so
your names never collide with another tenant's and you need no access to the host cluster.

## What reaches the host cluster

| Kind | On the host | Notes |
|---|---|---|
| Pods | Synced | The host runs them. On the host they all use one service account of your vcluster; inside the pod, the token is still that of your own ServiceAccount |
| Services, Endpoints, EndpointSlices | Synced | |
| PersistentVolumeClaims | Synced | They bind only in the StorageClasses on your vcluster's allowlist |
| PersistentVolumes | Created for your claims | The provisioners of the StorageClasses create them. Don't create or edit PVs yourself |
| Ingresses | Synced | Only hostnames on your vcluster's allowlist are accepted |
| ConfigMaps, Secrets | Only when used | Only those a synced object uses, for example in a pod's volumes or environment, or as an Ingress's TLS Secret. The others stay in your vcluster, so data your pods don't use never leaves it |
| VolumeSnapshots, VolumeSnapshotContents | Synced | No VolumeSnapshotClass is imported into your vcluster: see [Storage](../storage/README.md) |
| NetworkPolicies | Only with network isolation | Without it your vcluster accepts them, but they have no effect |
| ServiceMonitors, PodMonitors, HTTPRoutes, Traefik Middlewares, SecretStores, ExternalSecrets, Issuers, Certificates | Only with their switch | See [Features and allowlists](#features-and-allowlists-the-platform-sets) |
| Namespaces | Not synced | All your namespaces share `vcluster--<name>` |
| Deployments, StatefulSets, DaemonSets, ReplicaSets, Jobs, CronJobs, HorizontalPodAutoscalers | Not synced | Your vcluster's controllers run them; only their pods reach the host |
| ServiceAccounts, Roles, RoleBindings, ClusterRoles | Not synced | They grant access to your vcluster's API, never to the host |
| PodDisruptionBudgets | Not synced | Host node drains ignore them: see [Disruptions](../scheduling/disruptions/README.md) |
| PriorityClasses | Not synced | Your pods run on the host without a priority class, whatever `priorityClassName` you set |
| StorageClasses | Not synced | A class you create does not exist on the host |
| ResourceClaims, ResourceClaimTemplates | Not synced | |
| Custom resources of operators you install | Not synced | They stay in your vcluster, where your operators act on them |

Some objects come the other way, from the host into your vcluster, read-only:

| Kind | What you see in your vcluster |
|---|---|
| Nodes | Only the nodes that run your pods. Labels and taints you change on them never reach the host nodes |
| StorageClasses | Every host class, including the ones your vcluster may not use |
| IngressClasses | The host's ingress classes |
| GatewayClasses | Only with the gateway switch |
| Events | Host events about your objects, in `kubectl describe` and `kubectl get events` |
| Pod and node metrics | `kubectl top` works: see [Resource metrics](../autoscaling/README.md) |

The host's PriorityClasses, RuntimeClasses, VolumeSnapshotClasses, ConfigMaps and Secrets are not
imported.

## Names on the host

On the host, a synced object is named `<name>-x-<namespace>-x-vcluster--<vcluster>`, in the
namespace `vcluster--<vcluster>`. The Service `my-app` in `my-namespace` of the vcluster
`my-vcluster` becomes `my-app-x-my-namespace-x-vcluster--my-vcluster` in `vcluster--my-vcluster`.
A name longer than 63 characters is cut to its first 52 characters, followed by a dash and a
10-character hash.

Inside your vcluster you always use your own names: `kubectl`, selectors and Service DNS names
are unchanged. Host names appear where the host cluster reports on your workloads: platform
metrics and logs (see [Monitoring](../monitoring/README.md) and [Logging](../logging/README.md))
and messages from host policies. Short names keep them readable.

Your pods resolve names through your vcluster's own CoreDNS, which runs in its `kube-system`
namespace: `my-app.my-namespace.svc.cluster.local` works, but Services on the host and in other
vclusters do not resolve. See [DNS](../networking/dns/README.md) and
[Networking](../networking/README.md).

## Features and allowlists the platform sets

Each vcluster has its own settings. The platform team keeps them in the vcluster's configuration
and applies them on the host; nothing inside your vcluster can change them. The allowlists are
enforced on the host, so a vcluster can use only the storage, hostnames and restricted address
pools approved for it. Without a feature's switch, its objects stay in your vcluster and nothing
on the host acts on them.

| Setting | Default for a new vcluster | What it does | Guide |
|---|---|---|---|
| cert-manager | On | Issuers and Certificates sync to the host, where its cert-manager issues them | [TLS certificates](../certificates/README.md) |
| Prometheus monitors | On | ServiceMonitors and PodMonitors sync to the host, and the platform Prometheus scrapes your targets | [ServiceMonitor and PodMonitor](../serviceMonitor/README.md) |
| Gateway | Off | HTTPRoutes and Traefik Middlewares sync to the host, and the platform attaches your routes to the S3DF gateway | [HTTPRoutes](../httproutes/README.md) |
| External Secrets | Off | SecretStores and ExternalSecrets sync to the host, where the External Secrets Operator reads Vault; the Secret it writes appears in your vcluster | [External Secrets](../secrets/external-secrets/README.md) |
| Network isolation | On, with both profiles `default` | Platform network policies on your host namespace, one profile for incoming and one for outgoing traffic: `default` (all traffic), `vcluster` (your vcluster and platform services only) or `isolated`. Your NetworkPolicies sync to the host only when isolation is on | [Network isolation](../networking/network-policies/README.md) |
| StorageClasses | `wekafs--sdf-k8s01` | Claims in a class not on the list are rejected on the host and never bind. The list also holds `zfs--vcluster-etcd`, which is reserved for your vcluster's etcd: never use it | [Storage](../storage/README.md) |
| Ingress hostnames | None of your own | Ingresses for a host not on the list are rejected on the host | [Ingress](../ingresses/README.md) |
| HTTPRoute hostnames | None of your own | Routes for a hostname not on the list are not attached to the gateway | [HTTPRoutes](../httproutes/README.md) |
| MetalLB ingest pools | Not allowed | LoadBalancer Services in the ingest-network address pools are limited to the vclusters the platform lists | [LoadBalancer Services](../services/README.md) |
| Administrators | Set when the vcluster is created | Who is cluster-admin in your vcluster | [Logging in](access/README.md) |
| Pod tolerations | None | For a vcluster with its own node pool, the platform adds tolerations to every pod your vcluster syncs | [Node placement](../scheduling/README.md) |
| Control-plane size | Platform default | CPU and memory limits of your vcluster's API server and syncer | |

Existing vclusters may differ from these defaults. To find out what yours has, or to change it,
ask the platform team (s3df-help, `s3df-help@slac.stanford.edu`). Name your vcluster and say what
you need: the feature, each hostname, or each StorageClass.

The platform applies a change to your vcluster's control plane. Running pods are not restarted;
syncing between your vcluster and the host stops for a short time while the control plane elects
a new leader.

## Namespaces

Create a namespace for each application, and never use the vcluster's `default` namespace:
platform policy forbids it. `default` is where an object lands when a manifest or a command
forgets its namespace, so keeping it empty keeps every workload in a namespace you chose. Leave
`kube-system` to your vcluster's own components.

```bash
kubectl apply -f namespace.yaml          # or: kubectl create namespace my-namespace
kubectl config set-context --current --namespace=my-namespace
```

The second command makes `my-namespace` the namespace of your current context, so a command
without `-n` does not fall back to `default`. In a kustomization, `namespace:` sets the namespace
of every object, as in [`kustomization.yaml`](kustomization.yaml).

Don't name a namespace `test`. Each time the platform applies a change to your vcluster, it checks
the vcluster with test workloads in a namespace `test`, and then deletes that namespace with
everything in it.

## No quotas

The platform sets no ResourceQuota or LimitRange, in your vcluster or in its host namespace.
Nothing caps what your vcluster uses, and nothing fills in requests and limits a container leaves
out. Set them on every container: see [Requests and limits](../resources/README.md).

Your vcluster's etcd is small: each member has a 5Gi volume, shared by every object in your
vcluster. Keep large data out of ConfigMaps and Secrets, and keep Helm release histories short.

## What is backed up

The platform backs up your vcluster's etcd, which holds every object in your vcluster:

- **A daily etcd snapshot**, copied to S3 object storage.
- **ZFS snapshots of the etcd volumes**, taken several times an hour and kept only for a short
  time, on the nodes etcd runs on. Every vcluster whose etcd runs on ZFS, the default, has them.

The daily copy is stored away from the etcd volumes. The ZFS snapshots are a fast way back after
a recent mistake, but they are lost with the nodes they live on. Each copy holds the whole
control plane: restoring one rolls back every object in your vcluster, not only the one you lost.
Ask the platform team about a restore.

These backups hold only your vcluster's objects, never the data in your volumes: Weka,
node-local ZFS and S3DF filesystem claims are outside them. Back up your data with your application, for example
[CloudNativePG backups](../../operators/cloudnativepg/backups/README.md). Keep your manifests in
git, so that re-applying them restores an object you deleted, and keep the source of every Secret
in Vault (see [Secrets](../secrets/README.md)).

## Deleting a vcluster or a namespace

Your vcluster owns every object it creates on the host, so that deleting the vcluster removes them
all. When the platform deletes a vcluster:

- every synced object goes with it: pods, Services, Ingresses, ConfigMaps, Secrets and the rest;
- every claim goes with it. Weka and node-local ZFS volumes are deleted with their data, because
  their classes have reclaim policy `Delete`. Files on an S3DF filesystem share stay: see
  [S3DF filesystems](../storage/sdf-filesystem/README.md).

Deleting a namespace in your vcluster does the same for everything in it, including its claims:
Weka and node-local ZFS volumes lose their data.

## Examples

| File | What it shows |
|---|---|
| [`namespace.yaml`](namespace.yaml) | A namespace of your own |
| [`kustomization.yaml`](kustomization.yaml) | One namespace and its objects, applied together; `namespace:` puts every object in it |
| [`configmap.yaml`](configmap.yaml) | A ConfigMap that reaches the host because a pod mounts it |
| [`deployment.yaml`](deployment.yaml) | A Deployment that stays in your vcluster while its pods run on the host |
| [`service.yaml`](service.yaml) | A ClusterIP Service, with its DNS name inside your vcluster and its name on the host |

## Mistakes that break a workload or lose data

| Mistake | Result |
|---|---|
| Objects in the `default` namespace | Against platform policy, which forbids pods, Services and Ingresses there. Create a namespace and set it in your kustomization and your context |
| Your own workloads in a namespace named `test` | Deleted, with their claims, the next time the platform applies a change to your vcluster |
| A feature whose switch is off for your vcluster, for example an HTTPRoute without the gateway switch | Nothing on the host acts on the object: no route, no scrape, no Secret. Ask the platform team for the switch |
| A claim in a class not on your allowlist, or in a StorageClass you created | The host cluster rejects the synced claim, so it never binds |
| A claim in `zfs--vcluster-etcd` | The class places volumes only on the nodes reserved for vcluster etcd, where your pods cannot run, so the pod stays `Pending` |
| A PodDisruptionBudget to keep replicas up during host maintenance | It never reaches the host, so node drains ignore it |
| A PriorityClass and `priorityClassName` on your pods | No effect: the host runs your pods without a priority class |
| A NetworkPolicy in a vcluster without network isolation | Accepted, but never reaches the host and has no effect |
| Calling a Service of the host or of another vcluster by its DNS name | The name does not resolve. Use a LoadBalancer Service, an Ingress or an HTTPRoute: see [Networking](../networking/README.md) |
| Searching platform metrics or logs by the pod and namespace names of your vcluster | They are recorded under the host names, in namespace `vcluster--<name>` |
| Large files in ConfigMaps or Secrets, or a long Helm release history | Fills your vcluster's etcd; when it is full, writes to your vcluster's API fail |
| Counting on the platform backup for the data in your volumes | It holds only your vcluster's objects, never volume data |
| Deleting a namespace that holds Weka or node-local ZFS claims | The volumes and their data are deleted |

## Checking

Run these with your vcluster's context, never against the host cluster.

```bash
kubectl config current-context        # your vcluster
kubectl get nodes                     # only the nodes that run your pods
kubectl get storageclass              # every host class; your allowlist is a subset

kubectl apply -k .
kubectl -n my-namespace get deployment,pods,service,configmap
kubectl -n my-namespace exec deploy/my-app -- wget -qO- http://my-app:8080/

# Events from the host cluster, such as scheduling and volume errors, appear here too.
kubectl -n my-namespace describe pods -l app=my-app
kubectl -n my-namespace get events --sort-by=.lastTimestamp
kubectl -n my-namespace top pods
```

`kubectl delete -k .` removes the example, including `my-namespace` and everything in it.
