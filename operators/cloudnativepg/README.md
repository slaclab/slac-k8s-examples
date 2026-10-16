# PostgreSQL in your vcluster (CloudNativePG)

CloudNativePG (CNPG) is a Kubernetes operator that runs PostgreSQL from a `Cluster` object: it
creates the instances, their volumes, the replication between them, the TLS certificates, the
credentials and the Services that applications connect to. You install the operator in your own
vcluster, then describe each database as a `Cluster`. Use it for any PostgreSQL your application
needs; see [Operators and databases](../README.md) for the model.

Three platform features matter here. The default StorageClass `wekafs--sdf-k8s01` is on every
vcluster's allowlist and is the right one for a database. A LoadBalancer Service for clients
outside your vcluster needs a MetalLB pool your vcluster may use. Metrics reach the platform
Prometheus only if your vcluster has the Prometheus monitors switch. See
[Your vcluster](../../basic/vcluster/README.md#features-and-allowlists-the-platform-sets).

## How a database runs on the platform

1. You apply the operator (one Deployment in `cnpg-system`) and its CRDs in your vcluster. The
   platform does not run an operator for you: your vcluster does not sync CNPG objects to the host
   cluster, so the platform's own CNPG operator never sees your `Cluster`. The operator in your
   vcluster is yours to upgrade.
2. You create a `Cluster` in a namespace of your own. The operator creates one pod per instance,
   a PersistentVolumeClaim per instance (two with `walStorage`), the Secrets and the Services.
3. The vcluster syncs the pods, claims, the Secrets the pods use and the Services to the host
   cluster, where the Weka CSI driver provisions each claim as a directory with a hard quota and
   the host scheduler places the pods. Only Secrets a pod uses are synced; the platform does this
   so credentials stay inside your vcluster until something needs them.
4. On the host cluster, the platform adds the labels `app=cnpg` and `role=primary` or
   `role=replica` to the copy of every CNPG instance pod. Monitors, which select those host
   copies, must therefore select on the `cnpg.io/*` labels instead (see
   [Mistakes](#mistakes-that-lose-data-or-break-a-database)).
5. Pod disruption budgets stay in your vcluster: the platform does not sync them to the host. A
   host node drain therefore does not wait for your database. Run at least two instances so the
   operator can fail over, and keep `primaryUpdateStrategy: unsupervised` so it does so without
   you.

## Installing the operator

The files in this directory install a pinned upstream release with kustomize, the same way the
platform installs its own copy:

| File | What it does |
|---|---|
| [`Makefile`](Makefile) | `make resource` downloads the release manifest and splits it into `crd/` and `resources/`; `make dump` renders the result; `make apply` applies it |
| [`kustomization.yaml.tmpl`](kustomization.yaml.tmpl) | Template for `kustomization.yaml`: the namespace, `ns.yaml` and the patch. `make resource` adds one line per downloaded object |
| [`deployment-cnpg-manager-patch.yaml`](deployment-cnpg-manager-patch.yaml) | Raises the operator's memory limit from the upstream 200Mi to the 2Gi the platform runs with |
| [`ns.yaml`](ns.yaml) | The `cnpg-system` namespace |

The Makefile needs `kubectl`, `kustomize`, `curl` and the
[`kubectl slice`](https://github.com/patrickdappollonio/kubectl-slice) plugin.

```bash
# Point kubectl at your vcluster, then install. KUBECTL_DEPLOY_CONTEXT must name that context:
# the Makefile refuses to apply while another context is current.
make resource CNPG_VERSION_MAJOR=1.27 CNPG_VERSION_MINOR=1
make apply KUBECTL_DEPLOY_CONTEXT=my-vcluster

kubectl get deployment -n cnpg-system cnpg-controller-manager
kubectl get crd clusters.postgresql.cnpg.io poolers.postgresql.cnpg.io
```

`make apply` applies the CRDs with `kubectl apply --server-side --force-conflicts`. The `Cluster`
and `Pooler` CRDs are too large for client-side apply, whose last-applied annotation is limited to
256 KiB. The operator issues its own webhook certificate; it does not need cert-manager.

To upgrade, run the same two commands with the new version. CRDs and operator must come from the
same release: never apply one without the other. After the operator restarts it updates the
instance manager in every `Cluster` with a rolling restart, one instance at a time, ending in a
switchover of the primary: a short interruption during which clients reconnect. Upgrade one minor
at a time and read the upstream
[release notes](https://cloudnative-pg.io/docs/1.27/installation_upgrade/) first: some releases
change defaults.

Backups with the barman-cloud plugin are a separate install with their own prerequisites:
see [CloudNativePG backups to S3](backups/README.md).

## Cluster settings

| Field | Value | What it is for |
|---|---|---|
| `imageName` | A pinned tag, for example `ghcr.io/cloudnative-pg/postgresql:17.5` | The PostgreSQL image. A minor update (`17.5` to `17.6`) is a rolling restart. A new major (`17` to `18`) starts an offline `pg_upgrade` of the whole cluster: read the upstream procedure and back up first |
| `instances` | `2` or `3` | One primary plus streaming replicas. With `1`, any node problem stops the database |
| `primaryUpdateStrategy` | `unsupervised` | Lets the operator switch the primary over during restarts without waiting for you |
| `storage.storageClass` | `wekafs--sdf-k8s01` | The default class, on every vcluster's allowlist. Leave it out to get the same class |
| `storage.size` | The data volume, for example `50Gi` | A hard quota. PostgreSQL stops when it is full. Raise the value to grow the volume in place; it cannot be lowered |
| `walStorage` | Same class, a second size | A separate volume for the write-ahead log, so a WAL burst cannot fill the data volume |
| `resources` | Requests equal to limits | Gives the pods the `Guaranteed` QoS class, so they are the last to be evicted; see [Requests and limits](../../basic/resources/README.md) |
| `postgresql.parameters` | `postgresql.conf` settings | Keep `shared_buffers` near a quarter of the memory limit, and `max_wal_size` plus `wal_keep_size` inside `walStorage.size`. Setting any `pg_stat_statements.*` parameter makes the operator preload the library and create the extension in every database |
| `bootstrap.initdb.database`, `owner` | Your database and its owner role | Created once, when the cluster is first bootstrapped |
| `bootstrap.initdb.postInitApplicationSQL` | SQL run as superuser in that database | For `CREATE EXTENSION`. `postInitSQL` runs in the `postgres` database instead, where your tables are not |
| `bootstrap.initdb.secret.name` | A Secret of type `kubernetes.io/basic-auth` | Your own owner credentials, for example from Vault. Its `username` must equal `owner`. Leave it out and the operator generates them |

`bootstrap` is read only once. Changing `database`, `owner` or the SQL on a running cluster does
nothing; use the `Database` object or `psql` instead. The operator sets `logging_collector`,
`log_destination` and `shared_preload_libraries` itself and rejects them in `parameters`
(`kubectl apply` reports the error). It also sets pod anti-affinity by default, so instances
prefer different nodes.

### Huge pages

Leave `huge_pages` at PostgreSQL's default, `try`: the server uses huge pages if it gets them
and normal pages otherwise. With `on` it refuses to start when it gets none. A pod gets huge pages
only with a `hugepages-<size>` limit; ask the platform team (s3df-help) before you build on them,
as [Requests and limits](../../basic/resources/README.md#huge-pages) explains.

## Credentials and Services

The operator keeps the owner's credentials in the Secret `<cluster>-app` (type
`kubernetes.io/basic-auth`), unless you supplied `bootstrap.initdb.secret`, in which case your
Secret is used and `<cluster>-app` is not created. It holds:

| Key | Content |
|---|---|
| `username`, `user`, `password`, `dbname` | The owner role and your database |
| `host`, `port` | `<cluster>-rw` and `5432` |
| `uri`, `jdbc-uri` | Ready-made connection strings to `<cluster>-rw.<namespace>:5432` |
| `fqdn-uri`, `fqdn-jdbc-uri` | The same with the full `.svc.cluster.local` name |
| `pgpass` | A `.pgpass` line |

Give your application one of these keys with `secretKeyRef`, as
[`deployment-app.yaml`](cluster/deployment-app.yaml) does. The `postgres` superuser has no
network password unless you set `enableSuperuserAccess: true`, which then also creates `<cluster>-superuser`.

The operator creates three ClusterIP Services and keeps them pointing at the right instances
through failovers:

| Service | Reaches |
|---|---|
| `<cluster>-rw` | The primary. All writes go here |
| `<cluster>-ro` | The replicas only, for read-only queries |
| `<cluster>-r` | Any instance |

Connections are TLS by default. A client that wants to verify the server uses `ca.crt` from the
Secret `<cluster>-ca` with `sslmode=verify-full` and `host=<cluster>-rw.<namespace>.svc`.

## Clients outside your vcluster

The Services above, and their DNS names, exist only inside your vcluster. A client elsewhere on
the SLAC network, or in another vcluster, needs a Service of type `LoadBalancer` that selects the
database pods, following [LoadBalancer Services](../../basic/services/README.md): the
`metallb.io/address-pool` annotation and `allocateLoadBalancerNodePorts: false` are required by
the host, and `loadBalancerSourceRanges` should list only the client networks.

Put a `Pooler` in front of the database for such clients, as the examples do: PgBouncer accepts
many client connections and keeps a small, fixed number of connections to the primary, so a
burst of clients does not consume PostgreSQL's `max_connections` and memory. Select its pods with
`cnpg.io/poolerName: <pooler>`. For a client that needs session features (`SET`, advisory locks,
`LISTEN`), create a second `Pooler` with `poolMode: session`, or select the primary directly with
`cnpg.io/cluster: <cluster>` and `cnpg.io/instanceRole: primary`.

The database then listens on a SLAC address. Also restrict who can log in with `pg_hba` rules
(`postgresql.pg_hba` in the `Cluster`), and ask the platform team (s3df-help) before you use a
public pool.

## Monitoring

Each instance exposes a Prometheus exporter on port `metrics` (9187), and each PgBouncer pod one
on port `metrics` (9127). A `PodMonitor` in your namespace makes the platform Prometheus scrape
them, if your vcluster has the Prometheus monitors switch: the platform syncs your monitors to
the host, labels them for its Prometheus and limits them to your vcluster. Without the switch
the `PodMonitor` kind does not exist in your vcluster and `kubectl apply` fails. On the host all
your namespaces share one namespace, so a monitor selecting `cnpg.io/cluster: my-db` also scrapes
a cluster `my-db` in another of your namespaces: give clusters distinct names. See
[ServiceMonitor and PodMonitor](../../basic/serviceMonitor/README.md).

Write the `PodMonitor` yourself, as in [`podmonitor-cluster.yaml`](cluster/podmonitor-cluster.yaml).
`spec.monitoring.enablePodMonitor` is deprecated upstream and will be removed. Don't add
`prometheus.io/scrape` annotations to the pods: the platform Prometheus also scrapes annotated
pods, and without a `prometheus.io/port` it would try every container port, including 5432.

Add queries of your own with `monitoring.customQueriesConfigMap`; the operator's default queries
are included too.

## Deleting a cluster

Deleting the `Cluster` deletes its pods, Secrets, Services and claims, which the operator created
as owned by it. The claims are in a class with reclaim policy `Delete`, so the Weka directories
and the data in them are deleted too, at once and without a snapshot to restore from: see
[Weka CSI volumes](../../basic/storage/weka/README.md#deleting-a-claim). The same happens when
you delete the namespace. Take a backup first.

## Examples

| File | What it shows |
|---|---|
| [`cluster/cluster.yaml`](cluster/cluster.yaml) | A three-instance cluster on Weka with a WAL volume, `Guaranteed` resources, an extension created in the application database |
| [`cluster/deployment-app.yaml`](cluster/deployment-app.yaml) | An application reading `uri` from the Secret `my-db-app` and connecting to `my-db-rw` |
| [`cluster/pooler-rw.yaml`](cluster/pooler-rw.yaml) | A two-pod PgBouncer pool in transaction mode in front of the primary |
| [`cluster/service-loadbalancer-pooler.yaml`](cluster/service-loadbalancer-pooler.yaml) | A MetalLB address for the pool, for clients outside your vcluster |
| [`cluster/podmonitor-cluster.yaml`](cluster/podmonitor-cluster.yaml) | Scraping the instances with the platform Prometheus |
| [`cluster/podmonitor-pooler.yaml`](cluster/podmonitor-pooler.yaml) | Scraping PgBouncer |
| [`../../kubernetes/overlays/dev/cnpg-example-database/`](../../kubernetes/overlays/dev/cnpg-example-database/README.md) | A cluster whose owner credentials come from Vault through kustomize, on an image with extra extensions |

The manifests set no namespace. Apply them to a namespace of your own with `-n`: platform policy
forbids the vcluster's `default` namespace, and [Your vcluster](../../basic/vcluster/README.md)
shows how to create one.

```bash
kubectl apply -n my-namespace -f cluster/cluster.yaml
kubectl get cluster my-db -n my-namespace -w     # Setting up primary, then Cluster in healthy state

kubectl apply -n my-namespace -f cluster/deployment-app.yaml \
  -f cluster/pooler-rw.yaml -f cluster/service-loadbalancer-pooler.yaml

# Only with the Prometheus monitors switch on your vcluster.
kubectl apply -n my-namespace -f cluster/podmonitor-cluster.yaml -f cluster/podmonitor-pooler.yaml
```

## Mistakes that lose data or break a database

| Mistake | Result |
|---|---|
| `postInitSQL` for an extension your application needs | The extension is created in the `postgres` database. Your database does not have it. Use `postInitApplicationSQL` |
| A bootstrap Secret whose `username` differs from `owner`, or whose type is not `kubernetes.io/basic-auth` | Bootstrap fails or the owner's password is not set. The username must equal `owner` |
| `storage.size` sized for the data alone, with no `walStorage` | WAL growth, for example during a long transaction or a replica outage, fills the quota and PostgreSQL stops. Add `walStorage` and keep `max_wal_size` and `wal_keep_size` well inside it |
| `shared_buffers`, `work_mem` times `max_connections` and `maintenance_work_mem` that together exceed the memory limit | The kernel kills the instance (`OOMKilled`) under load. Size them from the limit, and use a `Pooler` instead of a large `max_connections` |
| `instances: 1`, or relying on `enablePDB` | A node drain or failure stops the database; the platform does not honour your pod disruption budgets. Run two or three instances |
| An LPP class (`sdf-group-*`, `sdf-data-*`) or `zfs--vcluster-etcd` as `storageClass` | LPP classes are shared `ReadWriteMany` shares without a quota, not a place for a database. `zfs--vcluster-etcd` is reserved for your vcluster's etcd and leaves the pods `Pending`. Use `wekafs--sdf-k8s01` |
| A `PodMonitor` that selects `app: cnpg` or `role: primary` | On the host every CNPG instance pod of your vcluster carries these labels, so the monitor scrapes all of them. Select on `cnpg.io/cluster` (plus `cnpg.io/instanceRole`), or `cnpg.io/poolerName` |
| `enablePodMonitor: true`, or a `prometheus.io/scrape` annotation | Deprecated, or scrapes the wrong ports. Write a `PodMonitor` |
| A `LoadBalancer` Service without `metallb.io/address-pool` or with `allocateLoadBalancerNodePorts` unset | The host rejects the Service and the address never appears; `kubectl describe service` shows the reason |
| Deleting the `Cluster` or the namespace to "restart" the database | The claims and the Weka directories are deleted. Delete pods or use `kubectl cnpg restart` instead |
| Uninstalling the operator, or deleting its CRDs, while clusters exist | Without the operator nothing manages failover, certificate renewal or restarts. Deleting the CRDs deletes every `Cluster` object, and with it the pods, claims and data |
| `imageName` with a new PostgreSQL major, applied like a minor update | The operator shuts down every instance and runs `pg_upgrade`; the database is unavailable meanwhile, replicas are re-cloned, and older backups can no longer be restored point-in-time. Plan it, back up first, and follow the [upstream procedure](https://cloudnative-pg.io/docs/1.27/postgres_upgrades/) |

## Checking

```bash
# Cluster status: primary, replicas, phase and the image in use.
kubectl get cluster -n my-namespace
kubectl describe cluster my-db -n my-namespace

# The pods and their roles, the claims and their sizes.
kubectl get pods -n my-namespace -l cnpg.io/cluster=my-db -L cnpg.io/instanceRole
kubectl get pvc -n my-namespace -l cnpg.io/cluster=my-db

# PostgreSQL's own log, JSON, one line per entry.
kubectl logs -n my-namespace my-db-1 | head

# The Services and the keys of the credentials Secret (no values).
kubectl get service -n my-namespace -l cnpg.io/cluster=my-db
kubectl get secret my-db-app -n my-namespace -o jsonpath='{.data}' | tr ',' '\n' | cut -d: -f1

# Why a pod is waiting: read the events at the end.
kubectl describe pod my-db-1 -n my-namespace

# The pool and its address, once the Service is applied.
kubectl get pooler -n my-namespace
kubectl get service my-db-external -n my-namespace
```

The [`kubectl cnpg`](https://cloudnative-pg.io/docs/1.27/kubectl-plugin) plugin adds
`kubectl cnpg status my-db -n my-namespace` (replication lag, certificates, instance details),
`kubectl cnpg psql my-db -n my-namespace` (a `psql` session on the primary) and
`kubectl cnpg promote`. Upstream documentation: [CloudNativePG](https://cloudnative-pg.io/docs/1.27/).
