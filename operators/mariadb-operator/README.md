# MariaDB in your vcluster (mariadb-operator)

mariadb-operator runs MariaDB from a `MariaDB` object: it creates the instance pod, its volume, its
configuration, its Service and a metrics exporter. `Database`, `User` and `Grant` objects manage
SQL databases and accounts, and `Backup` and `Restore` objects run logical backups to S3 and
restores from them. You install the operator in your own vcluster, from a pinned release, then
describe each database. See [Operators and databases](../README.md) for the model every operator
guide follows.

Four per-vcluster settings matter here. The default StorageClass `wekafs--sdf-k8s01` is on every
vcluster's allowlist. A LoadBalancer Service needs a MetalLB pool your vcluster may use;
`sdf-services` is open to every vcluster. The exporter's metrics reach the platform Prometheus only
with the Prometheus monitors switch, which is on by default. With a network isolation profile
other than `default`, traffic between your pods and the world outside the cluster is limited to
SLAC's ranges, which matters for outside clients and for the backup bucket. See
[Your vcluster](../../basic/vcluster/README.md#features-and-allowlists-the-platform-sets).

## How a database runs on the platform

1. You apply the operator's CRDs and its three Deployments in `mariadb-system`: the controller,
   the admission webhook, and the cert-controller, which issues the webhook's certificate. It
   does not need cert-manager. Your `MariaDB` objects never leave your vcluster, so no operator
   on the host acts on them.
2. You create a `MariaDB` in a namespace of your own. The operator creates a StatefulSet with one
   pod, a claim for its data, the Service `<name>`, and a ConfigMap from `myCnf`.
3. The vcluster syncs the pod, the claim and the Service to your host namespace,
   `vcluster--<name>`. The Weka CSI driver provisions the claim with a hard quota, and the host
   scheduler places the pod.
4. With `metrics.enabled`, the operator creates the exporter's SQL user and grant, an exporter
   Deployment and Service, and a ServiceMonitor. The platform syncs the ServiceMonitor to the host
   for its Prometheus.

The examples run one instance. PodDisruptionBudgets stay in your vcluster and do not hold off a
host node drain, so the database is down while its pod moves to another node. The Weka volume
mounts on any node with the Weka client, so the pod restarts there with its data. See
[Disruptions](../../basic/scheduling/disruptions/README.md).

## Installing the operator

[`operator/`](operator/) holds release 0.38.1, rendered from the upstream Helm charts with
`helm template` and split into one file per object by the
[`kubectl slice`](https://github.com/patrickdappollonio/kubectl-slice) plugin. You can read every
object before you apply it.

| Target | What it does |
|---|---|
| `make render VERSION=0.38.1` | Downloads the `mariadb-operator-crds` and `mariadb-operator` charts of that release and rewrites `crds/` and `resources/`. Needs `helm` and `kubectl slice` |
| `make apply KUBECTL_DEPLOY_CONTEXT=my-vcluster` | Applies the CRDs, `ns.yaml`, then `resources/` in `mariadb-system`. Refuses to run while another kubectl context is current |

```bash
cd operator
make apply KUBECTL_DEPLOY_CONTEXT=my-vcluster

kubectl get deployments -n mariadb-system     # mariadb-operator, -webhook, -cert-controller: 1/1
kubectl get crd mariadbs.k8s.mariadb.com
```

`make apply` applies the CRDs with `kubectl apply --server-side`: the `MariaDB` CRD is larger than
the 256 KiB annotation that client-side apply writes. Wait until all three Deployments are ready
before you create a `MariaDB`: until the webhook answers, the API server rejects the operator's
objects.

[`operator/mariadb-operator-values.yaml`](operator/mariadb-operator-values.yaml) sets requests
and limits for the three containers; the chart sets none. They are starting values: compare them
with `kubectl top pods -n mariadb-system`.

To upgrade, run `make render` with the new version, review the diff, then `make apply`. CRDs and
operator come from the same release. Read the upstream
[release notes](https://github.com/mariadb-operator/mariadb-operator/releases) first: some releases
need extra upgrade steps.

## MariaDB settings

| Field | Value | What it is for |
|---|---|---|
| `image` | A pinned tag, for example `docker-registry1.mariadb.com/library/mariadb:11.4.5` | The MariaDB server. A changed tag restarts the pod |
| `rootPasswordSecretKeyRef` | A key in a Secret you create | The root password. The operator's health probes log in with it |
| `storage.storageClassName` | `wekafs--sdf-k8s01` | The default class, on every vcluster's allowlist |
| `storage.size` | The data volume, for example `50Gi` | A hard quota: MariaDB stops writing when it is full. Raise it to grow the volume in place; the class allows expansion. Leave room for binary logs and temporary tables |
| `resources` | Memory request equal to the limit | The memory limit must hold `innodb_buffer_pool_size` plus per-connection buffers; otherwise the pod is `OOMKilled` under load. See [Requests and limits](../../basic/resources/README.md) |
| `myCnf` | `my.cnf` settings under `[mariadb]` | The operator puts them in a ConfigMap and restarts the pod when they change. Don't also set `myCnfConfigMapKeyRef`, which points the pod at a ConfigMap of your own instead |
| `service` | Type, annotations and source ranges of the Service `<name>` | Leave it out for a ClusterIP Service that only your vcluster reaches. See [Clients outside your vcluster](#clients-outside-your-vcluster) |
| `metrics.enabled`, `metrics.username`, `metrics.passwordSecretKeyRef` | `true`, a user name, a key in your Secret | The exporter and its SQL user. The operator creates that user and its grant; don't write them yourself |
| `metrics.exporter.image` | `prom/mysqld-exporter:v0.17.2` | Pinned. The operator needs v0.15.0 or later |

## Databases, users and grants

| Object | What the operator does |
|---|---|
| `Database` | Creates the database `spec.name` in the `MariaDB` that `mariaDbRef` names |
| `User` | Creates the account `spec.name`@`spec.host` with the password from `passwordSecretKeyRef`. `maxUserConnections` defaults to 10: set it to what the application opens |
| `Grant` | Grants `privileges` on `database`.`table` to `username`@`host` |

Object names must be DNS names (`my-app`), so set the SQL name in `spec.name` when it differs,
for example `my_app`. Applications in your vcluster connect to
`my-db.my-namespace.svc.cluster.local:3306`.

The `MariaDB` fields `username`, `passwordSecretKeyRef` and `database` also create a first user
and database, but that user is limited to 20 connections. The examples write the three objects
instead, so you control the limit.

## Secrets

The examples read the root, application and monitoring passwords and the S3 key from Vault with
[`database/Makefile`](database/Makefile), the method in
[Secrets from Vault at deploy time](../../basic/secrets/from-vault/README.md). Its `secretGenerator`
creates two Secrets:

| Secret | Keys | Used by |
|---|---|---|
| `my-db-users` | `root_password`, `user_password`, `monitoring_password` | `mariadb.yaml` (root, monitoring), `user.yaml` |
| `my-db-s3` | `access_key`, `secret_key` | `backup.yaml` |

The names have no hash suffix. kustomize does not rewrite Secret names inside custom resources,
so a hashed name would not match the references. A changed password in Vault therefore reaches
your vcluster only when you run `make apply` again. For the other ways to get a Secret, see
[Secrets](../../basic/secrets/README.md).

## Clients outside your vcluster

The Service `my-db` and its DNS name exist only inside your vcluster. For a client elsewhere on the
SLAC network, `mariadb.yaml` makes it a LoadBalancer Service, following
[LoadBalancer Services](../../basic/services/README.md). The host requires the
`metallb.io/address-pool` annotation and `allocateLoadBalancerNodePorts: false`, so that every
Service names the network its address comes from. `sdf-services` gives a private SLAC address.
`loadBalancerSourceRanges` admits only SLAC's ranges, `134.79.0.0/16` and `172.16.0.0/12`; narrow
it to your clients. Ask the platform team (s3df-help) before you use a public pool such as
`sdf-dmz`.

## Backups and restores

A `Backup` with a `schedule` becomes a CronJob that runs `mariadb-dump` and uploads the dump. The
backups are logical: SQL statements, not volume snapshots. Your vcluster has no VolumeSnapshotClass,
and the platform's backups do not include volume data, so these dumps are your only copy. See
[What is backed up](../../basic/vcluster/README.md#what-is-backed-up).

| Field | Value | What it is for |
|---|---|---|
| `storage.s3.endpoint` | `s3dfrgw.slac.stanford.edu` | S3DF object storage, without `https://`. Ask the platform team (s3df-help) for a bucket and an access key |
| `storage.s3.bucket`, `prefix` | Your bucket, a folder per database | Where the dumps go |
| `storage.s3.tls.enabled` | `true` | HTTPS to the endpoint |
| `maxRetention` | `720h` | Dumps older than this are deleted by the backup job. The default is 30 days |
| `stagingStorage` | A claim on `wekafs--sdf-k8s01` | Where the dump is written before upload, and before a restore reads it. Without it, an `emptyDir` on the node's local disk, where a large dump may not fit. Size it for one dump; set it on the `Restore` too |
| `args` | `--single-transaction` | A consistent InnoDB dump without locking tables |
| `resources` | Requests and limits | For the backup job's pod |

The platform's own MariaDB backs up to this endpoint. If your vcluster's outgoing isolation profile
is `vcluster` or `isolated`, pods reach only SLAC's ranges `134.79.0.0/16` and `172.16.0.0/12`
outside the cluster, so a bucket outside SLAC is blocked; see
[Networking](../../basic/networking/README.md#traffic-out-of-your-pods).

[`database/restore.yaml`](database/restore.yaml) restores the newest dump of `my-db-backup` into
`my-db`; with `spec.targetRecoveryTime` it takes the dump closest to that time. It is not in
the kustomization: apply it only when you mean to restore. The root password in
`rootPasswordSecretKeyRef` must be the one in the dump, or the probes fail and the pod restarts
after the restore.

## Monitoring

The operator's ServiceMonitor makes the platform Prometheus scrape the exporter on port 9104. The
platform adds the label its Prometheus selects on, so leave `metrics.serviceMonitor` out. Without
the Prometheus monitors switch, your vcluster has no ServiceMonitor kind: the operator records a
`CRDNotFound` warning on the `MariaDB` and creates neither the exporter nor its user. See
[ServiceMonitor and PodMonitor](../../basic/serviceMonitor/README.md).

## Examples

| File | What it shows |
|---|---|
| [`operator/Makefile`](operator/Makefile) | `make render` for a pinned release, `make apply` with server-side apply for the CRDs |
| [`operator/mariadb-operator-values.yaml`](operator/mariadb-operator-values.yaml) | The chart values `make render` uses: requests and limits for the three containers |
| [`operator/ns.yaml`](operator/ns.yaml) | The `mariadb-system` namespace |
| [`operator/crds/`](operator/crds/) | The CRDs of the release, one file each |
| [`operator/resources/`](operator/resources/) | The controller, webhook and cert-controller with their RBAC, Service and webhook configurations |
| [`database/mariadb.yaml`](database/mariadb.yaml) | One instance on Weka, with a LoadBalancer Service on `sdf-services` and the exporter |
| [`database/database.yaml`](database/database.yaml) | The database `my_app` |
| [`database/user.yaml`](database/user.yaml) | The account `my_app` with 100 connections |
| [`database/grant.yaml`](database/grant.yaml) | All privileges for `my_app` on `my_app.*` |
| [`database/backup.yaml`](database/backup.yaml) | A daily dump to S3DF object storage, kept 30 days, staged on Weka |
| [`database/restore.yaml`](database/restore.yaml) | A restore from that backup, staged on Weka |
| [`database/kustomization.yaml`](database/kustomization.yaml) | The objects above except the restore, and the two Secrets |
| [`database/Makefile`](database/Makefile) | Reads the Secrets' values from Vault, applies, deletes the files |
| [`database/.gitignore`](database/.gitignore) | Keeps `etc/.secrets/` out of git |

The manifests set no namespace. Platform policy forbids the vcluster's `default` namespace;
[Your vcluster](../../basic/vcluster/README.md#namespaces) shows how to create one. Replace the
bucket in `backup.yaml` and the Vault paths in the Makefile, then:

```bash
cd database
make apply KUBECTL_DEPLOY_CONTEXT=my-vcluster NAMESPACE=my-namespace \
  SECRET_PATH=secret/my-facility/my-vcluster/my-app/mariadb \
  S3_SECRET_PATH=secret/my-facility/my-vcluster/my-app/s3
kubectl get mariadb my-db -n my-namespace -w      # READY True, STATUS Running

# Only to restore:
kubectl apply -n my-namespace -f restore.yaml
```

## Mistakes that break or lose a database

| Mistake | Result |
|---|---|
| A `secretKeyRef` name or key that the `secretGenerator` does not create | The operator cannot read the password, and the object never becomes ready. Keep the names in `kustomization.yaml` and the references the same |
| A hash suffix on the generated Secrets | kustomize renames the Secrets but not the references in `MariaDB`, `User` and `Backup`. Keep `disableNameSuffixHash: true` |
| An underscore in `metadata.name`, such as `my_db` | The API server rejects the object. Use `-` in names and put the SQL name in `spec.name` |
| A `MariaDB` before the webhook Deployment is ready | `kubectl apply` fails with a webhook connection error. Wait for the three Deployments |
| A misspelt or unknown pool in `metallb.io/address-pool` | The Service gets no address: `EXTERNAL-IP` stays `<pending>`. Use `sdf-services` or a pool the platform team approved for you |
| A LoadBalancer without `metallb.io/address-pool` or with node ports | The host refuses the Service; `kubectl describe service` shows the reason |
| `innodb_buffer_pool_size` near or above the memory limit | The pod is `OOMKilled` under load. Keep it near half the limit |
| An application user left at `maxUserConnections` 10, or the `MariaDB` initial user at 20 | Connections beyond the limit fail with `max_user_connections`. Set `maxUserConnections` on a `User` |
| `myCnf` and `myCnfConfigMapKeyRef` both set | The pod reads the ConfigMap you name, not the one built from `myCnf`. Use one |
| Your own `User` or `Grant` for the exporter's user | Two owners for one SQL account. Let `metrics` create it |
| No `stagingStorage` for a large database | The dump goes to the node's local disk; when it does not fit, the backup or restore job fails. Set `stagingStorage` on both |
| A new root password without restoring a dump taken with it | After a restore, the probes fail with the old password and the pod restarts. Keep the root password with the backups |
| Deleting the namespace or the operator's CRDs | Deleting the namespace deletes the claims and the data in them. Deleting the CRDs deletes every `MariaDB`, `Backup` and other object of those kinds. Back up first |

## Checking

```bash
kubectl config current-context                             # your vcluster
kubectl get deployments -n mariadb-system

# Instance, SQL objects and backups: READY True when the operator has applied them.
kubectl get mariadb,database,user,grant -n my-namespace
kubectl get backup,restore -n my-namespace
kubectl describe mariadb my-db -n my-namespace              # events, such as CRDNotFound

# The pod, its claim and the Service; EXTERNAL-IP is <pending> until MetalLB assigns one.
kubectl get pods,pvc,svc -n my-namespace
kubectl describe service my-db -n my-namespace

# Backup runs and their logs.
kubectl get cronjobs,jobs -n my-namespace
kubectl logs -n my-namespace job/<job-name>

# The keys of the generated Secrets and their sizes, without the values.
kubectl describe secret my-db-users my-db-s3 -n my-namespace

# A SQL session as the application user; it prompts for the password.
kubectl exec -it -n my-namespace my-db-0 -- mariadb -u my_app -p my_app
```

Upstream documentation for this release: the
[mariadb-operator docs](https://github.com/mariadb-operator/mariadb-operator/tree/0.38.1/docs),
in particular [backups](https://github.com/mariadb-operator/mariadb-operator/blob/0.38.1/docs/BACKUP.md)
and [metrics](https://github.com/mariadb-operator/mariadb-operator/blob/0.38.1/docs/METRICS.md).
