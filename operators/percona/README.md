# MongoDB in your vcluster (Percona Operator for MongoDB)

The Percona Operator for MongoDB runs Percona Server for MongoDB from a `PerconaServerMongoDB`
object: it creates the replica set members, their volumes, the TLS certificates, the internal
users and the Services, and runs Percona Backup for MongoDB next to each member. You install the
operator in a namespace of your vcluster and describe each database as a `PerconaServerMongoDB` in
the same namespace. See [Operators and databases](../README.md) for the model every operator guide
follows.

Three per-vcluster settings matter here. The default StorageClass `wekafs--sdf-k8s01` is on every
vcluster's allowlist. The cert-manager switch, on by default for a new vcluster, lets host
cert-manager sign the certificates the operator asks for. The backup example reads its S3 key
from Vault with the External Secrets switch, which is off by default. See
[Your vcluster](../../basic/vcluster/README.md#features-and-allowlists-the-platform-sets), and ask
the platform team (s3df-help) to change a setting.

## How a database runs on the platform

1. `make apply` installs the operator from the pinned upstream `bundle.yaml`: four CRDs, and a
   Role, a ServiceAccount, a RoleBinding and the Deployment `percona-server-mongodb-operator` in
   your namespace. The operator watches only the namespace it runs in, so it and the databases it
   runs share one namespace. A database in another namespace needs its own operator there. That
   is the one exception to a single copy per vcluster: each copy owns only its namespace and the
   bundle has no webhooks, but the CRDs are cluster-wide, so every copy must be the same release.
2. You apply a `PerconaServerMongoDB`, `my-app-mongodb`. The operator creates the StatefulSet
   `my-app-mongodb-rs0`, with pods `my-app-mongodb-rs0-0` to `-2`, one claim per pod, the headless
   Service `my-app-mongodb-rs0`, and the Secrets it needs: the system users, the replica set key
   file, the data-at-rest encryption key, and the TLS certificates `my-app-mongodb-ssl` and
   `my-app-mongodb-ssl-internal`.
3. The vcluster syncs the pods, claims, Services and the Secrets the pods use to your host
   namespace, `vcluster--<name>`. The host scheduler places the pods and Weka provisions the
   claims. The `PerconaServerMongoDB` object stays in your vcluster, so the host never sees it.
4. TLS: if the cert-manager kinds exist in your vcluster, the operator creates a CA Certificate,
   the Issuers `my-app-mongodb-psmdb-ca-issuer` and `my-app-mongodb-psmdb-issuer`, and Certificates
   for the members, all with `kind: Issuer`. With the cert-manager switch on, host cert-manager
   signs them as described in [TLS certificates](../../basic/certificates/README.md). If the kinds
   are missing, the operator generates the CA and certificates itself into the same Secrets. Either
   way you write nothing. The kinds can exist without the switch, for example after it was turned
   off; then nothing issues the Certificates and the Secrets never appear.

## Installing the operator

[`mongodb/Makefile`](mongodb/Makefile) pins operator release `v1.23.1`. Run it with your
vcluster's context and your namespace:

```bash
cd mongodb
make dump                                   # download bundle.yaml and render the operator
make apply NAMESPACE=my-namespace KUBECTL_DEPLOY_CONTEXT=my-vcluster
```

`make apply` creates the namespace if it is missing, applies the operator with server-side apply
(the CRDs are too large for client-side apply), waits for the CRDs and the Deployment, then
applies `perconaservermongodb.yaml`. Set `DATABASE=perconaservermongodb-backups.yaml` for the
version with backups. [`deployment-operator-patch.yaml`](mongodb/deployment-operator-patch.yaml)
changes two things in the upstream Deployment:

| Change | Why |
|---|---|
| CPU and memory requests and limits | Upstream sets none, so the operator pod would have no reservation on the host node |
| `DISABLE_TELEMETRY: "true"` | Otherwise the operator reports usage to Percona's version service on the internet, which a vcluster with the `vcluster` or `isolated` outgoing profile cannot reach; see [Networking](../../basic/networking/README.md#traffic-out-of-your-pods) |

`bundle.yaml` is downloaded, not checked in, and `.gitignore` keeps it out of git. Read it before
you apply: `make dump` prints the operator objects that `make apply` sends, without the namespace.

## The database

[`perconaservermongodb.yaml`](mongodb/perconaservermongodb.yaml) is a three-member replica set:

| Field | Value | What it is for |
|---|---|---|
| `crVersion` | `1.23.1`, the installed operator's release | The operator applies the defaults and behaviour of this release. Raise it after each operator upgrade |
| `image` | `percona/percona-server-mongodb:8.0.32-14` | A full tag. Operator 1.23.1 is tested with 6.0.29-23, 7.0.43-23 and 8.0.32-14 |
| `upgradeOptions.apply` | `disabled` | The operator never changes the MongoDB version on its own; you change `image` |
| `replsets[].size` | `3` | A majority of members must agree to elect a primary, so three members survive the loss of one. The operator refuses a single member or an even number unless `unsafeFlags.replsetSize` is `true` |
| `replsets[].affinity.antiAffinityTopologyKey` | `kubernetes.io/hostname` | Requires each member to run on a different node, so one node failure takes one member. A member with no free node stays `Pending` |
| `replsets[].resources` | Requests and limits | The operator sizes the WiredTiger cache from the memory limit: half of the limit less 1 GiB, with a minimum. Set requests equal to limits for memory, so the node reserves it for the member |
| `replsets[].volumeSpec.persistentVolumeClaim.storageClassName` | `wekafs--sdf-k8s01` | Each member gets its own Weka volume with a hard quota. Size it with room for the oplog, and grow it before it fills |
| `enableVolumeExpansion` | `true` | To grow the volumes, raise `storage` in `volumeSpec`: the operator then resizes every member's claim. Without it, the operator keeps the old size. See [Weka](../../basic/storage/weka/README.md#growing-a-claim) |
| `secrets.users` | `my-app-mongodb-users` | The operator creates this Secret with generated passwords for its system users, such as the cluster admin, user admin and backup users. Leave it to the operator |
| `users` | `my-app`, `readWrite` on database `my-app` | An application user. With no `passwordSecretRef`, the operator generates the password into Secret `my-app-mongodb-custom-user-secret`, key `my-app` |
| `sharding.enabled` | `false` | A plain replica set. Sharding adds config servers and `mongos` routers; turn it on only when one replica set is not enough |
| `metadata.finalizers` | `percona.com/delete-psmdb-pods-in-order` | Stops the members in order when you delete the object |

`unsafeFlags` replaces the old `allowUnsafeConfigurations`. Don't set either for a database you
keep: they allow a single member, which loses the database with one volume.

The operator also creates a PodDisruptionBudget for the replica set. It stays in your vcluster and
does not protect members from a host node drain, so the three members are what keeps the database
up; see [Disruptions](../../basic/scheduling/disruptions/README.md).

## Connecting

Applications in your vcluster connect through the headless Service, which lists every member. For
each user in `users`, the operator writes connection strings into the Secret
`my-app-mongodb-custom-user-secret-conn-str`, under keys such as `my-app_rs0_connectionString`.
Map that key into the application's environment:

```yaml
env:
  - name: MONGODB_URI
    valueFrom:
      secretKeyRef:
        name: my-app-mongodb-custom-user-secret-conn-str
        key: my-app_rs0_connectionString
```

The default `tls.mode` is `preferTLS`: members talk to each other over TLS, and clients may connect
with or without it. To verify the server, give clients `ca.crt` from Secret `my-app-mongodb-ssl`.

Clients outside your vcluster are not covered here. The operator's `expose` with
`type: LoadBalancer` creates Services without `allocateLoadBalancerNodePorts: false`, which the
host refuses (see [LoadBalancer Services](../../basic/services/README.md)), and a replica set
client must reach every member by the name the replica set advertises. Ask the platform team
(s3df-help) if you need it.

## Backups

The platform's backups do not include the data in your volumes (see
[Backups](../README.md#backups)), so back up to S3.
[`perconaservermongodb-backups.yaml`](mongodb/perconaservermongodb-backups.yaml) is the same
database with backups on:

1. Ask the platform team (s3df-help) for a bucket on S3DF object storage,
   `https://s3dfrgw.slac.stanford.edu`, and an access key for it. Replace `bucket` with yours.
2. Store the access key and secret key in Vault under your vcluster's path and copy them into
   Secret `my-app-mongodb-backup-s3` with
   [`externalsecret-backup-s3.yaml`](mongodb/externalsecret-backup-s3.yaml), keys
   `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`. Replace the Vault path with your own. Without
   the External Secrets switch, make the Secret another way; see [Secrets](../../basic/secrets/README.md).
3. Apply the database. Each member pod gets a `backup-agent` sidecar, Percona Backup for MongoDB
   `2.15.0`. The task `daily` takes a logical backup once a day (`0 3 * * *`) into folder `my-app-mongodb` of the
   bucket and keeps the last 7, deleting older ones from the bucket.

| Field | Value | What it is for |
|---|---|---|
| `backup.storages.s3df.s3.endpointUrl` | `https://s3dfrgw.slac.stanford.edu` | S3DF object storage. Without it the agent looks for AWS |
| `backup.storages.s3df.s3.prefix` | `my-app-mongodb` | The folder in the bucket. Give every database its own |
| `backup.storages.s3df.s3.credentialsSecret` | `my-app-mongodb-backup-s3` | The Secret with the access key |
| `backup.tasks[].schedule`, `.retention` | Cron schedule, `type: count` | When backups run, and how many stay in the bucket |

[`backup.yaml`](mongodb/backup.yaml) takes a backup now, for example before an upgrade.
[`restore.yaml`](mongodb/restore.yaml) restores one into the running database and overwrites what
it holds. The platform's own databases back up to S3DF object storage directly, without the HTTP
proxy. With the `vcluster` or `isolated` outgoing profile, pods reach only SLAC ranges outside the
cluster, so a bucket outside SLAC is blocked; see
[Networking](../../basic/networking/README.md#traffic-out-of-your-pods). The bucket is the only copy outside your volumes: test a restore.

## Upgrading

The operator release and the MongoDB version are yours to upgrade; see
[Versions and upgrades](../README.md#versions-and-upgrades).

- Upgrade the operator one minor version at a time: set `PERCONA_MONGODB_VERSION`, run
  `make apply`, then set `crVersion` in your `PerconaServerMongoDB` to the same version.
- Upgrade MongoDB one major version at a time (6.0, 7.0, 8.0) by changing `image`, and move to a
  version the operator release supports before you upgrade past it: MongoDB 5.0 is not supported
  from operator 1.19.0.
- Before each step, take a backup with `backup.yaml`, and check `kubectl version` against
  Percona's [system requirements](https://docs.percona.com/percona-operator-for-mongodb/System-Requirements.html).

Upstream: [Upgrade the database and the operator](https://docs.percona.com/percona-operator-for-mongodb/update.html).

## Deleting

Deleting the `PerconaServerMongoDB` deletes its pods and StatefulSet, but not its claims, so the
data stays until you delete the claims or the namespace. Adding the finalizer
`percona.com/delete-psmdb-pvc` makes the operator delete the claims with the object. Deleting a
`PerconaServerMongoDBBackup` with the finalizer `percona.com/delete-backup`, as in `backup.yaml`,
deletes the backup's files from the bucket.

## Examples

| File | What it shows |
|---|---|
| [`mongodb/Makefile`](mongodb/Makefile) | Downloads the pinned operator bundle and applies it, then the database |
| [`mongodb/kustomization.yaml`](mongodb/kustomization.yaml) | The operator: `bundle.yaml` with the patch |
| [`mongodb/deployment-operator-patch.yaml`](mongodb/deployment-operator-patch.yaml) | Requests and limits, and telemetry off, for the operator Deployment |
| [`mongodb/.gitignore`](mongodb/.gitignore) | Keeps the downloaded `bundle.yaml` out of git |
| [`mongodb/perconaservermongodb.yaml`](mongodb/perconaservermongodb.yaml) | `my-app-mongodb`: three members on Weka, one application user |
| [`mongodb/perconaservermongodb-backups.yaml`](mongodb/perconaservermongodb-backups.yaml) | The same database with daily backups to S3DF object storage |
| [`mongodb/externalsecret-backup-s3.yaml`](mongodb/externalsecret-backup-s3.yaml) | The bucket's access key from Vault into Secret `my-app-mongodb-backup-s3` |
| [`mongodb/backup.yaml`](mongodb/backup.yaml) | An on-demand backup |
| [`mongodb/restore.yaml`](mongodb/restore.yaml) | A restore from that backup |

The two `perconaservermongodb*.yaml` files are alternatives with the same name: apply one.

## Mistakes that break or lose a database

| Mistake | Result |
|---|---|
| The database in a namespace without an operator | The object is stored and nothing creates its pods: the operator watches only its own namespace |
| Client-side `kubectl apply -f bundle.yaml` | The CRDs are rejected: the last-applied annotation is too large. Use `make apply` |
| `crVersion` different from the installed operator | The operator applies another release's defaults and behaviour to the database. Raise `crVersion` after each operator upgrade |
| Skipping operator minor versions, or MongoDB major versions | Not supported upstream: the upgrade can fail or leave members unable to start |
| `size: 1` with `unsafeFlags.replsetSize` or `allowUnsafeConfigurations` | One volume holds the only copy; any failure of it, or a restart, takes the database down |
| `expose.type: LoadBalancer` | The host refuses the Services: they stay `<pending>` with a `SyncError` event |
| A `storageClassName` not on your allowlist | The host refuses the claim, so the member stays `Pending`. Use `wekafs--sdf-k8s01` or a class the platform team added for you |
| A volume without room for the oplog | The Weka quota is hard: `mongod` stops writing when the volume is full |
| No backup, or backups never restored | The platform's backups do not include volume data. A deleted claim takes its data with it |
| Backups of two databases with the same `prefix` | Their backups mix in one folder. Give each its own |
| `upgradeOptions.apply` other than `disabled` | The operator asks Percona's version service for a newer MongoDB and upgrades on its schedule, or fails to reach it |

## Checking

```bash
kubectl config current-context                                   # your vcluster
kubectl get crd | grep psmdb.percona.com
kubectl -n my-namespace get deployment percona-server-mongodb-operator
kubectl -n my-namespace logs deployment/percona-server-mongodb-operator --tail=50

# STATUS is ready once all members are up.
kubectl -n my-namespace get perconaservermongodb my-app-mongodb
kubectl -n my-namespace get pods,pvc,svc -l app.kubernetes.io/instance=my-app-mongodb

# TLS: the Secrets exist. With the cert-manager switch, the Certificates are READY.
# If the kinds do not exist, the second command fails and the operator made the certificates.
kubectl -n my-namespace get secrets my-app-mongodb-ssl my-app-mongodb-ssl-internal
kubectl -n my-namespace get certificates,issuers

# Backups: status and the storage each one went to.
kubectl -n my-namespace get perconaservermongodbbackups
kubectl -n my-namespace get perconaservermongodbrestores

# A member that stays Pending: the host's reasons appear in its events.
kubectl -n my-namespace describe pod my-app-mongodb-rs0-0
```

Upstream reference: [Percona Operator for MongoDB](https://docs.percona.com/percona-operator-for-mongodb/)
and its [custom resource options](https://docs.percona.com/percona-operator-for-mongodb/operator.html).
