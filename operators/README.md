# Operators and databases in your vcluster (CloudNativePG, mariadb-operator, Percona, Strimzi)

An operator is a controller plus a set of custom resource definitions (CRDs) that runs a service
for you: you write one object that says what you want, for example a PostgreSQL `Cluster` with
two instances, and the operator creates and repairs the pods, volumes, credentials and Services
behind it. On the S3DF Kubernetes platform you install the operator in your own vcluster and run
your databases and message brokers with it. This page gives the model that every operator guide in
this directory follows; each guide then covers one operator.

Installing an operator needs no per-vcluster switch: you are cluster-admin in your vcluster, and
the operator, its CRDs and your database objects all stay there. Four per-vcluster settings
matter for the databases it runs: the StorageClass allowlist (the default class,
`wekafs--sdf-k8s01`, is on every list); the MetalLB ingest pools, for clients outside your
vcluster (`sdf-services` needs no approval, the ingest pools only for the vclusters listed for
them); the Prometheus monitors switch, on by default, for the operators' metrics; and network
isolation, on by default, without which an operator's NetworkPolicies never reach the host. See
[Your vcluster](../basic/vcluster/README.md#features-and-allowlists-the-platform-sets).

## How a database runs on the platform

1. You install the operator's CRDs and its controller Deployment in a namespace of your vcluster,
   for example `cnpg-system`. You are cluster-admin in your vcluster, so this needs no one else.
2. You create the database object, for example a CNPG `Cluster`, a `MariaDB`, a
   `PerconaServerMongoDB` or a `Kafka`, in a namespace of your own. The object is stored in your
   vcluster's etcd, and the operator in your vcluster acts on it.
3. The operator creates pods, PersistentVolumeClaims, Secrets, ConfigMaps and Services. The
   vcluster syncs the pods, the claims, the Services and the Secrets and ConfigMaps the pods use
   to your host namespace, `vcluster--<name>`, and the host cluster runs them: its scheduler
   places the pods and the storage driver provisions the volumes.
4. Pod status and host events come back to your vcluster, so `kubectl get` and `kubectl describe`
   on the database object and its pods show what happened on the host.

The database object itself stays in your vcluster. The vcluster syncs only the kinds the host must
run, listed in [What reaches the host cluster](../basic/vcluster/README.md#what-reaches-the-host-cluster),
and custom resources of operators you install are not among them. The host cluster runs a
CloudNativePG operator for platform services, but your `Cluster` objects never reach it. If the
CRDs are installed but the operator is not running, nothing creates the database's pods: the
object is stored and ignored, or, when the operator's admission webhook is registered but its
pod is not running, the API server can reject it with a webhook error.

Because the operator lives in your vcluster, its CRDs, webhooks and version are yours alone: you
choose when to upgrade, and an operator upgrade or CRD change in one vcluster never affects
another.

## Operators with a guide here

| You need | Operator | Guide | Objects you write |
|---|---|---|---|
| PostgreSQL | CloudNativePG (CNPG) | [PostgreSQL with CloudNativePG](cloudnativepg/README.md), and [backups to S3](cloudnativepg/backups/README.md) | `Cluster`, `Pooler`, `ScheduledBackup`, `Backup`, and `ObjectStore` of the barman-cloud plugin |
| MariaDB or MySQL | mariadb-operator | [MariaDB with mariadb-operator](mariadb-operator/README.md) | `MariaDB`, `Database`, `User`, `Grant`, `Backup`, `Restore` |
| MongoDB | Percona Operator for MongoDB | [MongoDB with the Percona operator](percona/README.md) | `PerconaServerMongoDB`, `PerconaServerMongoDBBackup`, `PerconaServerMongoDBRestore` |
| Kafka | Strimzi | [Kafka with Strimzi](strimzi/README.md) | `Kafka`, `KafkaNodePool`, `KafkaTopic`, `KafkaUser` |

Each guide pins one upstream release of its operator, so the version you install is fixed and you
can read every object before you apply it. Then it shows the database objects.

The `mysql/` directory holds an older example for the Oracle MySQL operator. It is not maintained
and has no guide: its Makefile downloads the operator's manifests from the `trunk` branch instead
of a release, so what it installs changes from one run to the next. For a MySQL-compatible
database use mariadb-operator.

## Versions and upgrades

The operator in your vcluster is yours: you choose its version, and you upgrade it. The platform
upgrades neither tenant operators nor the databases they run, because it never sees them. Expect
to do this work:

| What | Who | How |
|---|---|---|
| Operator release | You | The guides pin one release, in a Makefile variable or in the checked-in manifests. Change the version, render the manifests, review what changed, then apply. Read the operator's upgrade notes first: some releases need an intermediate version, and some change their CRDs. Stay on a release the project still supports |
| CRDs | You | Apply the CRDs of the controller's release, before the controller. An object that uses a field the installed CRDs lack is rejected with `unknown field` |
| Database engine image | You | The database object names its image, for example `imageName` in a CNPG `Cluster` or `image` in a `MariaDB`. Pin a full version tag: with a floating tag, the version an instance runs depends on when its image was pulled |
| Kubernetes version of your vcluster | The platform team | `kubectl version` shows it as the server version. An operator release supports a range of Kubernetes versions: check it when you pick a release, and when the platform team upgrades your vcluster |

Install exactly one copy of an operator in a vcluster. CRDs and webhook configurations are
cluster-wide objects inside your vcluster, so a second copy, for example from a Helm chart that
bundles the operator as a dependency, fights the first over the same objects. If an application
chart bundles an operator you already run, turn that dependency off.

Operators can also create admission webhooks, PodDisruptionBudgets and NetworkPolicies. The
webhooks run in your vcluster and check your objects before they are stored. PodDisruptionBudgets
never reach the host, so a host node drain does not wait for your database: run at least two
instances of anything that must stay up, and see
[Disruptions](../basic/scheduling/disruptions/README.md). NetworkPolicies reach the host only in a
vcluster with network isolation, which is on by default; see
[Network isolation](../basic/networking/network-policies/README.md). Check that an operator's
NetworkPolicies are in force before you count on them as a security control.

## Storage for databases

Every operator asks for its volumes through PersistentVolumeClaims, and each claim needs a class
on your vcluster's StorageClass allowlist. Choose the class with the operator's own field, not with
a claim you write yourself:

| Operator | Field |
|---|---|
| CloudNativePG | `spec.storage.storageClass`, and `spec.walStorage.storageClass` for a separate WAL volume |
| mariadb-operator | `spec.storage.storageClassName` |
| Percona MongoDB | `volumeSpec.persistentVolumeClaim.storageClassName` on each replica set |
| Strimzi | `class` on each volume in `spec.storage` of a `KafkaNodePool` |

Use `wekafs--sdf-k8s01`, the default class, unless the platform team has set up a class for your
workload. It is on every vcluster's allowlist, it gives each instance a volume of its own with a
hard quota, and every node with the Weka client can mount its volumes, so an instance pod can
start on another node after a node failure. The size you give the operator is the quota: a
database that fills it stops writing. Pick a size with room for the engine's own files
(write-ahead logs, binlogs, oplog, Kafka segments), and grow the volume before it fills: the class
allows expansion, see [Growing a claim](../basic/storage/weka/README.md#growing-a-claim). For the
choice between classes, see [Storage: choosing a StorageClass](../basic/storage/README.md); for a
database that keeps its own replicas on local disks, see
[Node-local ZFS](../basic/storage/node-local-zfs/README.md).

Two kinds of class are wrong for a database: an S3DF filesystem class (`sdf-group-<facility>` and
the like), which mounts a shared tree that every claim in the class sees and supports only
`ReadWriteMany`; and `zfs--vcluster-etcd`, which is reserved for your vcluster's own etcd. See
[S3DF filesystems](../basic/storage/sdf-filesystem/README.md).

## Backups

The platform backs up your vcluster's etcd, so the operator and the database objects can be
restored, but the platform's backups do not include the data in your volumes, and volume snapshots
are not available in a vcluster. A deleted Weka claim takes its data with it. CloudNativePG,
mariadb-operator and the Percona operator can write backups to S3 object storage: use that, and
test a restore. For PostgreSQL see [CloudNativePG backups to S3](cloudnativepg/backups/README.md).
Strimzi has no backup object: Kafka keeps data by replicating it across brokers, so give topics a
replication factor above one. Don't configure a backup method that relies on volume snapshots. See
[What the platform backs up](../basic/storage/README.md#what-the-platform-backs-up).

## Credentials

Operators create or consume credentials as Secrets. Where a guide's Makefile fills Secrets from
Vault, the Vault path and the secret names in its manifests are placeholders for your own. Never
put a password in a manifest. The Secrets an operator generates, such as a CNPG cluster's
application credentials, are what your application reads; mount them or map them into environment
variables as the guides show. See [Secrets](../basic/secrets/README.md) for the ways a Secret gets
into your vcluster.

## Clients and monitoring

Inside your vcluster, applications connect through the Service the operator creates, by its DNS
name, for example `my-db-rw.my-namespace.svc.cluster.local`. Your vcluster's Service names do not
resolve on the host or in other vclusters, so a client outside your vcluster needs a LoadBalancer
Service with an address from a MetalLB pool your vcluster may use, such as `sdf-services`. See
[LoadBalancer Services](../basic/services/README.md) for the settings the host requires; the
CloudNativePG guide puts one in front of a connection pooler.

Operators expose Prometheus metrics; some create a PodMonitor or ServiceMonitor for you, and for
the others you write one. Monitors reach the platform Prometheus only in a vcluster with the
Prometheus monitors switch, which is on by default; see [Monitoring](../basic/monitoring/README.md)
and [ServiceMonitor and PodMonitor](../basic/serviceMonitor/README.md).

## Mistakes that break or lose a database

| Mistake | Result |
|---|---|
| Applying a database object without installing its operator | Your vcluster has no such kind, so `kubectl apply` fails with `no matches for kind`. If only the CRDs are installed, the object is stored and nothing creates its pods |
| Expecting the host's CloudNativePG operator to run your `Cluster` | Your `Cluster` never reaches the host. Install the operator in your vcluster |
| Applying with a kubectl context other than your vcluster's | The objects go to whatever cluster that context points at, or are refused there. Check `kubectl config current-context` first, and set a Makefile's context variable, where it has one, to your vcluster's context |
| Two copies of one operator in a vcluster, for example a chart dependency next to your install | Both act on the same CRDs and webhook configurations: objects flap or are rejected. Keep one |
| Operator and CRDs from different releases | An object that uses a field the CRDs lack is rejected with `unknown field`, and the controller ignores fields it does not know. Apply the CRDs of the controller's release |
| A floating image tag, such as `latest` or a bare major version, for the engine | The version an instance runs depends on when its image was pulled, so instances can differ and a restart can change the version. Pin a full version |
| A class not on your allowlist, or a class left to a chart's default such as `standard` | The host rejects the claim, so the instance pod stays `Pending`. Use `wekafs--sdf-k8s01` or a class the platform team added for you |
| An S3DF filesystem class for a database volume | Every claim in the class gets the whole share, not a private volume. Use the Weka class |
| A volume sized without room for logs and segments | The quota is hard: the engine stops writing when the volume is full. Grow it before that |
| Relying on PodDisruptionBudgets to survive host maintenance | They never reach the host. Run two or more instances and let the operator fail over |
| Backups by volume snapshot, or no backup at all | No VolumeSnapshotClass exists in a vcluster, and the platform's backups do not include volume data. Back up to S3 from the database |
| Deleting a database's namespace | Every claim in the namespace is deleted: Weka and node-local ZFS volumes lose their data |
| Deleting an operator's CRDs, for example to uninstall it | Kubernetes deletes every object of those kinds in your vcluster, and the objects they own. CloudNativePG's claims belong to their `Cluster`, so their data goes too |
| Deleting the database object before taking a backup | Some operators delete the instance claims with the object; CloudNativePG does. Back up first, and read the operator's guide on deletion |
| Objects in the `default` namespace | Against platform policy, which forbids pods and Services there. Create a namespace for the operator and one per database |

## Checking

Run these with your vcluster's context. Each operator guide has its own checks; these show whether
the model above holds for you.

```bash
kubectl config current-context                 # your vcluster, never the host
kubectl version                                # Server Version: your vcluster's Kubernetes

# The CRDs each operator installed. A kind that is missing here cannot be applied.
kubectl get crd | grep -E 'cnpg.io|mariadb.com|percona.com|strimzi.io'

# The operators' controllers, each in the namespace its guide installs it in.
kubectl get deployments --all-namespaces

# Your database objects, one command per operator you installed, then their pods, claims and Services.
kubectl get clusters.postgresql.cnpg.io -n my-namespace
kubectl get mariadbs -n my-namespace
kubectl get perconaservermongodbs -n my-namespace
kubectl get kafkas -n my-namespace
kubectl get pods,pvc,svc -n my-namespace

# A pod that stays Pending: the host's reasons appear in its events.
kubectl describe pod my-db-1 -n my-namespace
kubectl get events -n my-namespace --sort-by=.lastTimestamp
```

Upstream reference: the [Kubernetes operator pattern](https://kubernetes.io/docs/concepts/extend-kubernetes/operator/)
and the operators' own documentation, linked from each guide.
