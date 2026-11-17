# CloudNativePG backups to S3 (barman-cloud plugin)

CloudNativePG (CNPG) backs up a PostgreSQL cluster by archiving its write-ahead log (WAL) and
taking base backups into an S3 bucket, with the barman-cloud plugin. The two together give
point-in-time recovery: a new cluster can be built with the data as it was at any moment covered
by the archive. Use this for every CNPG cluster whose data you cannot recreate. The platform does
not back up the data in your volumes, so without it a deleted database, or a bad `DELETE`, is
final. For the cluster itself, see [PostgreSQL with CloudNativePG](../README.md).

Three things must be in place before a backup can run:

- The barman-cloud plugin installed next to your CNPG operator, in `cnpg-system` of your vcluster.
  It needs the cert-manager switch, which is on by default; see
  [Installing the plugin](#installing-the-plugin).
- A bucket on S3DF object storage and an access key for it, from the platform team (s3df-help).
- The External Secrets switch, to bring the key from Vault into a Secret. The switch is off by
  default; see [Your vcluster](../../../basic/vcluster/README.md#features-and-allowlists-the-platform-sets).

## What the platform backs up, and what it does not

The platform backs up each vcluster's etcd: a daily copy to object storage and frequent ZFS
snapshots. That copy holds your Kubernetes objects, including the `Cluster`, its Secrets and the
claims, but not the PostgreSQL data in the volumes. Volume snapshots are not available either:
your vcluster has no VolumeSnapshotClass, and the host has none for tenant volumes (see
[Storage](../../../basic/storage/README.md#what-the-platform-backs-up)). So `method: volumeSnapshot`
cannot work, and the only way to protect a database is a backup that the database makes itself:
WAL archiving and base backups to S3.

Deleting a `Cluster` deletes its claims and their data. A `Cluster` with a working WAL archive and
a recent base backup can be rebuilt from the bucket. One without them cannot.

## How a backup works

Write an ObjectStore, a Cluster with the plugin, and a ScheduledBackup in the same namespace.
Everything runs inside your vcluster: the ObjectStore, Cluster, ScheduledBackup and Backup
objects stay there, and the host cluster sees only the pods they produce.

1. The CNPG operator adds a `plugin-barman-cloud` sidecar to every instance pod. The sidecar
   reads the ObjectStore and the S3 Secret it names.
2. PostgreSQL hands every finished WAL segment to the sidecar, which uploads it to
   `<destinationPath>/<serverName>/wals/`. CNPG closes a segment at least every 5 minutes
   (`archive_timeout`), so the archive is never more than about 5 minutes behind.
3. On each ScheduledBackup run, and for each Backup object you create, the sidecar on the chosen
   instance takes a base backup, online, and uploads it to `<destinationPath>/<serverName>/base/`.
   With `target: prefer-standby`, the default, it runs on the most up-to-date replica, so the
   primary keeps serving.
4. On a timer (`retentionPolicyIntervalSeconds`), the sidecar on the primary deletes base
   backups older than `retentionPolicy` and the WAL files that only they needed, and removes the
   `Backup` objects whose files are gone.

The bucket is on S3DF object storage, `https://s3dfrgw.slac.stanford.edu`. The platform's own
CloudNativePG databases back up to it directly, without the HTTP proxy. If your vcluster's
outgoing isolation profile is `vcluster` or `isolated`, pods may reach only the SLAC ranges
`134.79.0.0/16` and `172.16.0.0/12` outside the cluster, so a bucket outside SLAC, for example on
AWS, is blocked; see [Networking](../../../basic/networking/README.md#traffic-out-of-your-pods).

The restore is a new cluster, never the same one: CNPG replays the base backup and the WAL into
fresh volumes, in the same or another namespace, or in another vcluster that can read the bucket.

## Installing the plugin

The plugin runs as a Deployment, `barman-cloud`, in the same namespace as your CNPG operator,
`cnpg-system`. Your vcluster runs its own CNPG operator and its own plugin: the host's CNPG
manages only platform services, and your `Cluster` objects never leave your vcluster. The plugin needs CNPG
1.26 or later, and talks to the operator over mutual TLS with certificates that cert-manager
issues, so the cert-manager switch must be on for your vcluster (it is on by default; see
[TLS certificates](../../../basic/certificates/README.md)).

```bash
# The operator version: 1.26 or later.
kubectl get deployment -n cnpg-system cnpg-controller-manager \
  -o jsonpath='{.spec.template.spec.containers[*].image}{"\n"}'

# cert-manager kinds exist in your vcluster: the switch is on.
kubectl api-resources --api-group=cert-manager.io

# The plugin, from the upstream release. Pin a version; check the release page for the current one.
kubectl apply -f https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/v0.15.1/manifest.yaml
kubectl -n cnpg-system rollout status deploy/barman-cloud

# Its certificates. Both must be Ready before the first backup.
kubectl get certificates -n cnpg-system
```

The manifest installs the `ObjectStore` CRD (`barmancloud.cnpg.io/v1`), RBAC, a Service and
Deployment `barman-cloud`, an Issuer `selfsigned-issuer` and the Certificates
`barman-cloud-client` and `barman-cloud-server`. Those Certificates sync to the host, are signed
there and come back. A vcluster without the cert-manager switch has no Certificate kind, so the
apply fails for those objects and the plugin stays unreachable, unless you run your own
cert-manager in the vcluster. Before you upgrade the operator or the plugin, check the plugin's
release notes for the CNPG versions it supports.

## The ObjectStore

| Field | Value | What it is for |
|---|---|---|
| `configuration.destinationPath` | `s3://<bucket>/<folder>` | Where backups go. barman adds a folder per `serverName` under it, so one bucket can hold several clusters |
| `configuration.endpointURL` | `https://s3dfrgw.slac.stanford.edu` | S3DF object storage. Required: without it barman looks for AWS |
| `configuration.s3Credentials.accessKeyId`, `.secretAccessKey` | `name` of the Secret and the `key` inside it | The bucket's access key and secret key |
| `configuration.wal.compression`, `configuration.data.compression` | `gzip` (also `bzip2`, `lz4`, `snappy`; `xz`, `zstd` for WAL only) | Smaller uploads. Uncompressed by default |
| `configuration.wal.maxParallel` | A small integer | WAL segments uploaded, or fetched on restore, at once. One at a time by default |
| `configuration.data.jobs` | A small integer | Parallel uploads of one base backup. Default 2 |
| `retentionPolicy` | `"30d"` (`d`, `w` or `m`) | The recovery window. Base backups older than it, and the WAL only they need, are deleted, except the newest one that still covers the whole window. Without it nothing is ever deleted |
| `instanceSidecarConfiguration.resources` | Requests and limits | For the sidecar in each instance pod. It has none by default |
| `instanceSidecarConfiguration.retentionPolicyIntervalSeconds` | Seconds | How often the retention policy is enforced. 1800 (30 minutes) by default |
| `configuration.serverName` | Leave empty | Kept for compatibility with the old in-tree configuration. Set `serverName` on the Cluster's plugin entry instead |

### The S3 credentials

Store the access key and secret key in Vault under your vcluster's path, and bring them into a
Secret with an ExternalSecret, as in
[`externalsecret-s3-credentials.yaml`](externalsecret-s3-credentials.yaml). Never put them in a
manifest. The Secret must be in the namespace of the ObjectStore. The ObjectStore and the
ExternalSecret agree on the Secret name, `my-app-db-backup-s3`, and on the keys `ACCESS_KEY_ID`
and `ACCESS_SECRET_KEY`; the Vault field names (`access-key`, `secret-key` in the example) are
yours to choose. See [External Secrets](../../../basic/secrets/external-secrets/README.md) for the
Vault path and the store. A vcluster without the External Secrets switch can make the Secret with
the Makefile flow in [Secrets](../../../basic/secrets/README.md) instead.

## The Cluster

The Cluster names the ObjectStore in `spec.plugins`, as in [`cluster.yaml`](cluster.yaml):

| Field | Value | What it is for |
|---|---|---|
| `plugins[].name` | `barman-cloud.cloudnative-pg.io` | The plugin |
| `plugins[].enabled` | `true` | |
| `plugins[].isWALArchiver` | `true` | Makes the plugin the WAL archiver. Exactly one plugin per cluster may have it |
| `plugins[].parameters.barmanObjectName` | The ObjectStore's name | Which ObjectStore to archive to. It must be in the cluster's namespace |
| `plugins[].parameters.serverName` | A name, by default the cluster name | The folder under `destinationPath`. Every cluster that ever writes to a bucket needs its own |
| `backup.target` | `prefer-standby` (default) or `primary` | Which instance takes base backups |
| `walStorage` | A second claim | WAL on its own volume, so a stalled archive fills it and not the data volume |

Do not set `backup.barmanObjectStore` on the same cluster: the in-tree configuration and the
plugin exclude each other, and the in-tree one is deprecated since CNPG 1.26. The plugin starts
archiving as soon as the primary starts. The archive alone is useless: only a base backup makes
it restorable, so create the ScheduledBackup with the cluster and set `immediate: true`.

## The ScheduledBackup

| Field | Value | What it is for |
|---|---|---|
| `schedule` | Six fields, seconds first: `"0 0 2 * * *"` is 02:00:00 daily | When base backups run. Not CronJob syntax: the five-field `"0 2 * * *"` is accepted with a warning and read as second 0, minute 2 of every hour |
| `method` | `plugin` | Required with the plugin. The default, `barmanObjectStore`, is the in-tree method |
| `pluginConfiguration.name` | `barman-cloud.cloudnative-pg.io` | |
| `cluster.name` | The Cluster | |
| `immediate` | `true` | Take the first backup now |
| `backupOwnerReference` | `self` | The ScheduledBackup owns the Backup objects it creates, so they are deleted with it. `none` keeps them |
| `suspend` | `true` | Pauses the schedule without deleting it |
| `target` | `primary` or `prefer-standby` | Overrides `backup.target` for this schedule |

Each run creates a `Backup` object in the namespace; `kubectl get backups` lists them with their
phase. For a one-off backup, create a `Backup` yourself, as in [`backup.yaml`](backup.yaml), or run
`kubectl cnpg backup my-app-db -n my-namespace --method=plugin --plugin-name=barman-cloud.cloudnative-pg.io`
with the [cnpg kubectl plugin](https://cloudnative-pg.io/docs/1.27/kubectl-plugin).

Daily is a reasonable default: a restore replays every WAL segment since the base backup, so
more frequent backups make restores faster, not the data more recent. The recovery point is set
by the WAL archive, about 5 minutes.

## Restoring

A restore creates a new `Cluster` with `bootstrap.recovery`, in the same namespace as the
ObjectStore, and an `externalClusters` entry that says where to read from. The original cluster
can keep running. [`cluster-restore.yaml`](cluster-restore.yaml) restores the latest base backup
and every WAL segment after it; [`cluster-restore-pitr.yaml`](cluster-restore-pitr.yaml) stops at a
moment in time.

| Field | Value | What it is for |
|---|---|---|
| `bootstrap.recovery.source` | The `externalClusters[].name` | Which entry to read from |
| `externalClusters[].plugin.name` | `barman-cloud.cloudnative-pg.io` | |
| `externalClusters[].plugin.parameters.barmanObjectName` | The ObjectStore | Must be in the new cluster's namespace |
| `externalClusters[].plugin.parameters.serverName` | The original cluster's `serverName` | Which folder of the bucket to read. Defaults to the new cluster's name, which is wrong for a restore |
| `bootstrap.recovery.recoveryTarget.targetTime` | RFC 3339 with a time zone, for example `"2026-10-13T16:30:00-07:00"` | Point-in-time recovery: stop at this moment. A time without a zone is read as UTC. Recovery fails if no transaction follows it in the archive |
| `bootstrap.recovery.recoveryTarget.backupID` | A backup ID from `kubectl get backups` | Which base backup to start from. Without it, the newest one before `targetTime`, or the newest overall |
| `bootstrap.recovery.database`, `.owner` | Your application's database and owner | The application database and owner of the new cluster |
| `bootstrap.recovery.secret.name` | Optional: an existing `kubernetes.io/basic-auth` Secret | The owner's credentials. Without it, the operator generates a new password in `<cluster>-app` |
| `imageName` | The same major version as the backup | A base backup restores only into the PostgreSQL major it came from |
| `spec.plugins` | A plugin entry with a new `serverName` | So that the new cluster archives its own WAL. Without one it has no backups |

Backups hold no Kubernetes Secrets. The restored cluster gets its own `<cluster>-app` Secret with
a new password, so your application's connection details change, unless you create a Secret with
the old credentials first and name it in `bootstrap.recovery.secret`.

The new cluster must not archive under the original `serverName`: both clusters would write to
one WAL folder, and neither could be restored. CNPG checks that the folder it is about to archive
to is empty; if it is not, the new cluster does not start, and its pod log shows
`Expected empty archive`. Never set the annotation that skips this check.

```bash
# The point in time the archive covers, and the newest base backup.
kubectl get cluster my-app-db -n my-namespace \
  -o jsonpath='first={.status.firstRecoverabilityPoint} last={.status.lastSuccessfulBackup}{"\n"}'

kubectl apply -n my-namespace -f cluster-restore.yaml
kubectl get cluster my-app-db-restored -n my-namespace -w   # "Setting up primary", then "Cluster in healthy state"

# Check the data, then point the application at my-app-db-restored-rw and delete the old cluster.
kubectl cnpg psql my-app-db-restored -n my-namespace -- -d my-app -c '\dt'
```

To restore in another vcluster, or after the original namespace is gone, create the ObjectStore
and its Secret there first: the bucket is the only thing the restore needs.

## Examples

| File | What it shows |
|---|---|
| [`externalsecret-s3-credentials.yaml`](externalsecret-s3-credentials.yaml) | The access key and secret key from Vault into Secret `my-app-db-backup-s3` |
| [`objectstore.yaml`](objectstore.yaml) | An ObjectStore for a bucket on S3DF object storage, compressed, with a 30-day window |
| [`cluster.yaml`](cluster.yaml) | A Cluster that archives WAL and takes base backups through the plugin |
| [`scheduledbackup.yaml`](scheduledbackup.yaml) | A daily base backup at 02:00, with the first one now |
| [`backup.yaml`](backup.yaml) | A one-off base backup |
| [`cluster-restore.yaml`](cluster-restore.yaml) | A new cluster from the latest backup and all WAL since, archiving under a new name |
| [`cluster-restore-pitr.yaml`](cluster-restore-pitr.yaml) | A new cluster with the data as of one moment in time |
| [`kustomization.yaml`](kustomization.yaml) | The first four files, for `kubectl apply -k` |

The manifests set no namespace. Apply them to a namespace of your own with `-n`: platform policy
forbids the vcluster's `default` namespace, and [Your vcluster](../../../basic/vcluster/README.md)
shows how to create one. The ObjectStore, the Secret, the Cluster and the ScheduledBackup must be
in the same namespace. Before you apply, replace the bucket in `objectstore.yaml` and the Vault
path in `externalsecret-s3-credentials.yaml` with your own.

```bash
kubectl apply -k . -n my-namespace
kubectl get objectstore,cluster,scheduledbackup,backup -n my-namespace
```

## Mistakes that leave a database without a backup

| Mistake | Result |
|---|---|
| Counting on the platform's etcd backup | It restores your `Cluster` object, which then starts empty. The data was only in the volumes |
| `method: volumeSnapshot`, or `backup.volumeSnapshot` on the Cluster | Fails: your vcluster has no VolumeSnapshotClass |
| No ScheduledBackup, or one that never ran | WAL is archived but there is no base backup to apply it to, so nothing can be restored. `status.firstRecoverabilityPoint` stays empty |
| A cluster without `isWALArchiver: true` | Base backups only: a restore gets the state at the last backup, and point-in-time recovery is impossible |
| `method` left at its default on the ScheduledBackup | The default is the in-tree `barmanObjectStore`, which the cluster does not configure, so every Backup fails |
| `backup.barmanObjectStore` and a plugin with `isWALArchiver` on one cluster | Rejected: the two exclude each other |
| Two clusters with the same `serverName` in one `destinationPath` | The second does not start: the WAL folder is not empty (`Expected empty archive`). If the check is skipped, both archives are mixed and neither is restorable |
| A restore without `serverName` in the `externalClusters` entry | It defaults to the new cluster's name, so CNPG finds no backup and the restore fails |
| A restored cluster without `spec.plugins` | It runs without any backup of its own |
| `targetTime` without a time zone | Read as UTC, so the cluster is restored to a moment hours from the one you meant |
| A Kubernetes CronJob schedule in `schedule` | Accepted with only a warning, and shifted one field: `"0 2 * * *"` takes a base backup every hour at two minutes past, not daily at 02:00 |
| No `retentionPolicy` | The bucket grows forever |
| A plugin that is installed but has no cert-manager | Its Certificates never become Ready, the operator cannot reach it, and the cluster does not start or does not archive |
| The access key in a manifest or a ConfigMap | Anyone who can read your namespace, or your git repository, can read and delete your backups |
| Deleting the ObjectStore or its Secret while the cluster runs | WAL archiving stops, `ContinuousArchiving` goes `False`, and WAL accumulates on the WAL volume until it is full and PostgreSQL stops accepting writes |

A WAL volume that fills up stops the database. Watch `ContinuousArchiving` (below), and give the
WAL volume room for a few hours of archive failure.

## Checking

```bash
# Archiving and the last backup, as the operator sees them.
kubectl get cluster my-app-db -n my-namespace \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
# ContinuousArchiving=True ContinuousArchivingSuccess
# LastBackupSucceeded=True LastBackupSucceeded

# How far back a restore can go, and when the last base backup finished.
kubectl get cluster my-app-db -n my-namespace \
  -o jsonpath='first={.status.firstRecoverabilityPoint} last={.status.lastSuccessfulBackup}{"\n"}'

# Every base backup, with its phase; the error column says why one failed.
kubectl get backups -n my-namespace

# The sidecar's log on an instance: uploads, and the reason for a failed one.
kubectl logs my-app-db-1 -n my-namespace -c plugin-barman-cloud --tail=50

# The Secret the ExternalSecret made, by name only.
kubectl get externalsecret,secret my-app-db-backup-s3 -n my-namespace
```

`kubectl cnpg status my-app-db -n my-namespace` prints the same with the WAL archive state and
the list of backups. A `ContinuousArchiving` condition of `False` names the failing upload in its
message; the usual causes are a wrong bucket name, a wrong key, or a Secret the ObjectStore
cannot find.

Upstream reference: [the barman-cloud plugin](https://cloudnative-pg.io/plugin-barman-cloud/docs/intro/),
and in the CloudNativePG documentation [Backup](https://cloudnative-pg.io/docs/1.27/backup),
[WAL archiving](https://cloudnative-pg.io/docs/1.27/wal_archiving) and
[Recovery](https://cloudnative-pg.io/docs/1.27/recovery).
