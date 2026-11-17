# Secrets from Vault (External Secrets Operator)

An ExternalSecret copies values from S3DF Vault into a Kubernetes Secret in your vcluster, and
updates the Secret when the values change in Vault. Use it for passwords, tokens and keys: the
ExternalSecret holds only Vault paths and key names, so it can live in git with the rest of your
manifests. For the other ways to make Secrets from Vault, see [Secrets](../README.md).

ExternalSecrets work only in a vcluster where the platform team has turned on the External
Secrets switch, which is off by default. The switch gives the vcluster its own Vault policy, Vault
role and store on the host cluster, so the platform team sets it up per vcluster. Ask the
platform team (s3df-help), and see
[Your vcluster](../../vcluster/README.md#features-and-allowlists-the-platform-sets).

## How an ExternalSecret becomes a Secret

Write the ExternalSecret inside your vcluster. The platform does the rest:

1. The vcluster copies the ExternalSecret to the host cluster, into your host namespace
   `vcluster--<name>`, and renames it and its `spec.target.name` there.
2. If the ExternalSecret carries the annotation `edu.stanford.slac.sdf.secrets/s3df-vault: "true"`,
   Kyverno sets `spec.secretStoreRef` on the host copy to the store that the Vault path names (see
   [Choosing the store](#choosing-the-store)).
3. The External Secrets Operator (ESO), which runs once on the host for every vcluster, logs in to
   Vault as the `default` ServiceAccount of `vcluster--<name>` and reads the values.
4. ESO writes the Secret on the host. The vcluster copies it back into the ExternalSecret's
   namespace under the name in `spec.target.name`, and copies the ExternalSecret's `status` to
   your object.
5. Every `refreshInterval`, ESO reads Vault again and updates the Secret.

Your vcluster runs no operator and holds no Vault credential. On the host, the ExternalSecret and
its Secret carry host names, `<object>-x-<namespace>-x-vcluster--<name>` (see
[Names on the host](../../vcluster/README.md#names-on-the-host)); in your vcluster you use your own.

## What your vcluster can read

With the switch on, your vcluster has a ClusterSecretStore on the host cluster named
`<facility>-<name>`, and a Vault role of the same name. The role can read and list everything
below `secret/<facility>/<name>/`, plus any path the platform team adds for your vcluster:

| Vault path | Readable |
|---|---|
| `secret/<facility>/<name>/my-app/db`, and any other path below `secret/<facility>/<name>/` | Yes |
| `secret/<facility>/<name>`, the entry itself | No: access starts one level below it |
| `secret/<facility>/<other-vcluster>/...` | No |
| A path the platform team has added for your vcluster | Yes, through your own store |

Vault decides by the host namespace that ESO logs in from: your vcluster's role accepts only
`vcluster--<name>`, and nothing in your vcluster can change that namespace. This keeps each
vcluster to its own paths, so use your own store and no other.

- `<facility>` is the facility your vcluster belongs to, and `<name>` the vcluster name. Ask the
  platform team if you don't know your facility.
- Every namespace in your vcluster reads the same paths: Vault sees one identity per vcluster.
  Anyone who can create an ExternalSecret in your vcluster can read every value your vcluster
  may read.
- The platform team can add read access to other paths, for example the Dex client secret of your
  application's login client (see [Logging users in](../../authentication/README.md)).
- The S3DF Vault default policy lets every Vault user list the path names under `secret/`. Keep
  sensitive information out of path names.

### Storing the values

Write the values under your vcluster's path with the Vault CLI. If you cannot write there, ask the
platform team.

```bash
export VAULT_ADDR=https://vault.slac.stanford.edu
vault login -method=ldap    # add username=<SLAC username> if it differs from your local one

# Read the password without echo, so it stays out of your shell history.
read -rs DB_PASSWORD
printf '%s' "$DB_PASSWORD" | \
  vault kv put secret/my-facility/my-vcluster/my-app/db username=my-app password=-
unset DB_PASSWORD

vault kv list secret/my-facility/my-vcluster/my-app
```

The CLI path starts with the mount, `secret/`. In an ExternalSecret, `remoteRef.key` leaves it out:
`my-facility/my-vcluster/my-app/db`. `vault kv put` replaces every field of the entry; to change
one field, use `vault kv patch`.

## Choosing the store

Every ExternalSecret needs a store, and your vcluster's store is the ClusterSecretStore
`<facility>-<name>`. There are two ways to set it:

| What you write | Store ESO uses |
|---|---|
| The annotation, and `spec.data` | `<a>-<b>`, from the first two segments of `spec.data[0].remoteRef.key`: `my-facility/my-vcluster/my-app/db` gives `my-facility-my-vcluster`. It replaces any `secretStoreRef` you wrote |
| The annotation, and only `spec.dataFrom` | None: the platform reads only `spec.data[0]`. Set `secretStoreRef` yourself |
| No annotation, and `secretStoreRef` with `kind: ClusterSecretStore`, `name: <facility>-<name>` | The store you name |

The annotation exists so that you don't need to know the store name: it follows from the Vault
path. The store it sets serves every entry of the ExternalSecret. With the annotation, put an
entry from your own path first; entries from paths the platform team added for you can follow it.

## ExternalSecret settings

| Field | Value | What it is for |
|---|---|---|
| `apiVersion` | `external-secrets.io/v1` | The version the platform copies to the host. The host no longer serves `v1beta1`, which older examples use |
| `metadata.annotations` | `edu.stanford.slac.sdf.secrets/s3df-vault: "true"`, exactly | The platform sets the store for you |
| `spec.secretStoreRef` | `kind: ClusterSecretStore`, `name: <facility>-<name>` | The store, when you don't use the annotation |
| `spec.data[].remoteRef.key` | `<facility>/<name>/<path>`, without `secret/` or `data/` | The Vault entry |
| `spec.data[].remoteRef.property` | A field of the entry, for example `password` | The value to copy |
| `spec.data[].secretKey` | A key name, for example `password` | The key in the Secret |
| `spec.dataFrom[].extract.key` | `<facility>/<name>/<path>` | Copies every field of the entry, under the field names |
| `spec.target.name` | The Secret's name, for example `my-app-db` | Always set it: the platform copies back into your vcluster only the Secret that this field names |
| `spec.target.template` | See [Templates](#templates) | Builds the Secret's type and keys from the values |
| `spec.refreshInterval` | A duration; default `1h` | How often ESO reads Vault again. `0s` reads once and never updates |

## Templates

`spec.target.template` builds the Secret from the values, instead of copying them one to one:

- `template.data` maps each key of the Secret to a Go template. `{{ .password }}` is the value
  that `spec.data` reads under `secretKey: password`. The template functions include `b64enc` and
  `toJson`: `toJson` quotes and escapes a value, so a password with quotes or colons still gives a
  valid YAML or JSON file.
- `template.type` sets the Secret's type, for example `kubernetes.io/dockerconfigjson` for an image
  pull secret.
- With `template.data`, the Secret holds only the templated keys. Add `mergePolicy: Merge` to keep
  the keys from `spec.data` as well.

## Refresh and rotation

After you change a value in Vault, the Secret follows at the next refresh, within
`refreshInterval`. Each refresh is a Vault read by the one ESO that serves every vcluster, so
keep `1h` unless your rotation needs to be faster.

Running pods see the new value only through a Secret volume:

- Environment variables (`env`, `envFrom`) are read when the container starts. Restart the pods:
  `kubectl rollout restart deployment/my-app -n my-namespace`.
- Files in a Secret volume change without a restart, and the application must read them again. A
  volume mounted with `subPath` never changes.

## Examples

The examples use the facility `my-facility`, the vcluster `my-vcluster`, and Vault entries under
`secret/my-facility/my-vcluster/my-app/`. Replace them with yours.

| File | What it shows |
|---|---|
| [`externalsecret.yaml`](externalsecret.yaml) | Two fields of `my-app/db` in Secret `my-app-db`, with the store set by the platform |
| [`externalsecret-datafrom.yaml`](externalsecret-datafrom.yaml) | Every field of `my-app/env` in Secret `my-app-env`, with the store named in the manifest |
| [`externalsecret-templated-config.yaml`](externalsecret-templated-config.yaml) | A config file, `config.yaml`, rendered from fields of `my-app/db` and `my-app/api` |
| [`externalsecret-image-pull-secret.yaml`](externalsecret-image-pull-secret.yaml) | A `kubernetes.io/dockerconfigjson` pull secret for `ghcr.io`, from `my-app/registry` (see [Container images](../../images/README.md)) |
| [`deployment.yaml`](deployment.yaml) | my-app using the four Secrets: `env`, `envFrom`, a volume and `imagePullSecrets` |

The manifests set no namespace. Apply them to a namespace of your own with `-n`: platform policy
forbids the vcluster's `default` namespace, and [Your vcluster](../../vcluster/README.md) shows how
to create one. The Deployment's image, `ghcr.io/my-org/my-app:1.0.0`, stands for your own.

```bash
kubectl apply -n my-namespace -f externalsecret.yaml
kubectl get externalsecret my-app-db -n my-namespace   # STATUS SecretSynced, READY True
kubectl get secret my-app-db -n my-namespace           # appears after the first sync
```

## Mistakes that break an ExternalSecret or expose a secret

| Mistake | Result |
|---|---|
| The switch is off for your vcluster | Your vcluster has no store and no Vault role, so no Secret is created. Ask the platform team |
| `apiVersion: external-secrets.io/v1beta1` | Not served. Use `external-secrets.io/v1` |
| The annotation, with a key that starts with the mount, for example `secret/my-facility/my-vcluster/my-app/db` | The platform derives the store `secret-my-facility`, which does not exist, so the ExternalSecret never syncs. Leave out `secret/` and `data/` |
| The annotation, with `spec.data[0]` on a path the platform team added for you | The store derived from that path is not your vcluster's, so the read fails. Put an entry from your own path first, or drop the annotation and set `secretStoreRef` |
| The annotation, with only `spec.dataFrom` | No store is set, so the ExternalSecret never syncs. Set `secretStoreRef` |
| Neither the annotation nor `secretStoreRef` | No store, so the ExternalSecret never syncs |
| A value at `secret/<facility>/<name>` itself | Vault denies the read. Put it one level down, for example `secret/<facility>/<name>/my-app` |
| Any store other than `<facility>-<name>`, for example another vcluster's | Not supported. Another vcluster's store fails: its Vault role accepts only that vcluster's host namespace. To read a path outside your own, ask the platform team to add it for your vcluster |
| A SecretStore of your own | Not supported: an ExternalSecret in your vcluster does not find it. Use your vcluster's ClusterSecretStore, which the platform team sets up with your vcluster's Vault role |
| A PushSecret, ClusterExternalSecret or generator | Not supported: the platform copies only ExternalSecrets and SecretStores to the host |
| Editing the Secret in your vcluster | The edit never reaches Vault, because your vcluster's role can only read, and the Vault value replaces it. Change the value in Vault |
| `template.data` that names some of the keys | The Secret holds only the templated keys. Add `mergePolicy: Merge` to keep the others |
| Sensitive words in a Vault path name | Every Vault user can list path names |
| A short `refreshInterval` on many ExternalSecrets | Load on Vault and on the ESO that every vcluster shares. Keep `1h` unless your rotation needs to be faster |
| Environment variables from the Secret, after a change in Vault | Running containers keep the old value. Restart the pods, or read the value from a Secret volume |

## Checking

```bash
kubectl get externalsecret -n my-namespace

# Why an ExternalSecret is not Ready.
kubectl get externalsecret my-app-db -n my-namespace \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}{"\n"}'

# The keys of the Secret and their sizes, without the values.
kubectl describe secret my-app-db -n my-namespace
```

| STATUS | READY | Meaning |
|---|---|---|
| `SecretSynced` | `True` | The Secret matches Vault as of LAST SYNC |
| `SecretSyncedError` | `False` | The last read failed. The message says why: for example an entry or property that does not exist, a path your vcluster may not read, a store that does not exist, or a template error |
| Empty | Empty | No status has reached your vcluster yet. If it stays empty, the ExternalSecret has not reached the host: ask the platform team whether your vcluster has the switch |

The STORE column shows what you wrote. For an ExternalSecret with the annotation it stays empty,
because the platform sets the store on the host copy only.

The platform runs ESO 2.8. Upstream references: the
[ExternalSecret API](https://external-secrets.io/latest/api/externalsecret/) and
[templating](https://external-secrets.io/latest/guides/templating/).
