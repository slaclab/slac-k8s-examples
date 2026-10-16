# Vault secrets as VaultSecrets (vault-secrets-operator)

A VaultSecret copies one Vault KV entry into a Kubernetes Secret of the same name. The
vault-secrets-operator (by ricoberger) does the copying from inside your vcluster. It runs only in
the vclusters where it has been installed, so check for it first (see [Checking](#checking)). If
your vcluster has the External Secrets switch, use an [ExternalSecret](../external-secrets/README.md)
for new secrets instead: it keeps no Vault credential in your vcluster. To compare the methods, see
the [secrets overview](../README.md); for the per-vcluster switches, see
[Your vcluster](../../vcluster/README.md#features-and-allowlists-the-platform-sets).

## How a VaultSecret becomes a Secret

Create the VaultSecret in the namespace of the pods that use it. The operator does the rest:

1. The operator runs in your vcluster, as the Deployment `vault-secrets-operator` in the namespace
   `vault-secrets-operator`, and watches VaultSecrets in every namespace.
2. It logs in to Vault at `https://vault.slac.stanford.edu` with an AppRole, whose credentials are
   in a Secret in the operator's namespace, and reads `spec.path`.
3. It creates a Secret with the VaultSecret's name, in the same namespace, of type `spec.type`,
   with the VaultSecret's labels and annotations. The Secret holds the keys in `spec.keys`, every
   key of the entry if `keys` is absent, or only the keys that `spec.templates` builds.
4. The VaultSecret owns the Secret, so deleting the VaultSecret deletes the Secret.

The operator reads Vault with its AppRole, not with your own Vault login. The AppRole's Vault
policy decides which paths a VaultSecret can read, and everyone who can create VaultSecrets or read
the operator's Secret in your vcluster can read those paths. Leave the `vault-secrets-operator`
namespace as it is: every VaultSecret in your vcluster depends on the operator and its login. For
access to a new path, ask the platform team (s3df-help).

## When the Secret changes

How often the operator reads Vault again depends on how it is set up in your vcluster, through its
environment variable `VAULT_RECONCILIATION_TIME` (see [Checking](#checking)):

| `VAULT_RECONCILIATION_TIME` | The operator reads Vault again |
|---|---|
| A number of seconds, for example `60` | At that interval, and it updates the Secret when the value in Vault has changed |
| `0` | Only when the VaultSecret's `spec` changes, when the Secret is deleted, or when the operator restarts. A change in Vault does not reach the Secret on its own |

A label or annotation change on the VaultSecret does not make the operator read Vault. To pick up a
new value now, delete the Secret: the operator creates it again from the current value. Files
mounted from the Secret change in running pods after a short delay. Restart the pods that read it
as environment variables.

## VaultSecret settings

| Field | Value | What it is for |
|---|---|---|
| `spec.path` | `secret/my-facility/my-vcluster/my-app/db` | The Vault KV path, including the `secret/` mount. Don't add `data/`: the operator adds it. Required |
| `spec.type` | `Opaque`, or another Secret type such as `kubernetes.io/dockerconfigjson` | The type of the Secret. Required |
| `spec.keys` | A list of keys of the Vault entry | Copies only these keys. Leave it out to copy every key |
| `spec.templates` | Secret key: template | Builds each key from the entry's values. Templates use `{%` and `%}`, and `.Secrets` holds the entry's keys: `{% index .Secrets "password" %}` |
| `spec.version` | A KV version number | Pins one version of the Vault entry. Leave it out to use the latest |
| `spec.reconcileStrategy` | `Replace` (default) or `Merge` | `Merge` keeps keys of the Secret that Vault does not have |
| `spec.isBinary` | `true` | For values stored base64-encoded in Vault: the Secret then holds the decoded bytes |

## Examples

| File | What it shows |
|---|---|
| [`vaultsecret.yaml`](vaultsecret.yaml) | The keys `username` and `password` of one Vault entry, as the Secret `my-app-db` |
| [`vaultsecret-template.yaml`](vaultsecret-template.yaml) | The same Vault entry, reshaped by templates into the Secret `my-app-db-env` |
| [`deployment.yaml`](deployment.yaml) | A Deployment that reads `my-app-db-env` as environment variables and mounts `my-app-db` as files |

The manifests set no namespace. Apply them to a namespace of your own with `-n`: platform policy
forbids the vcluster's `default` namespace.

```bash
kubectl apply -n my-namespace -f vaultsecret.yaml -f vaultsecret-template.yaml -f deployment.yaml
kubectl get vaultsecret -n my-namespace    # SUCCEEDED True, REASON Created or Updated
kubectl rollout status deployment/my-app -n my-namespace
```

## Mistakes that leave a Secret missing or stale

| Mistake | Result |
|---|---|
| `{{ }}` in `spec.templates` | Not a template for this operator: the Secret holds the text `{{ ... }}` as written |
| `data/` in `spec.path`, or a path without `secret/` | The read fails: `SUCCEEDED False`, `REASON FetchFailed` |
| A key in `spec.keys` that Vault does not have | The Secret lacks the key, without an error. A pod that needs it fails with `CreateContainerConfigError`. If none of the keys exist, the read fails with `FetchFailed` |
| A template that names a key Vault does not have | With `index`, the key holds an empty string, without an error |
| A path that the operator's AppRole may not read | `FetchFailed` with a permission error. Ask the platform team (s3df-help); the operator retries on its own, so the Secret appears once access is granted |
| Expecting the Secret to follow Vault, with `VAULT_RECONCILIATION_TIME` `0` | It keeps the old value until the VaultSecret's `spec` changes or you delete the Secret |
| Adding a label or annotation to refresh the Secret | Nothing happens: the operator acts only on changes to `spec` |
| The VaultSecret in a different namespace from its pods | The Secret is created in the VaultSecret's namespace, so the pods don't find it |
| Editing the generated Secret by hand | The operator replaces your change the next time it reads Vault. Change the value in Vault instead |
| Deleting the VaultSecret | Its Secret is deleted too. New pods that use it don't start |
| Using VaultSecrets in a vcluster without the operator | `kubectl apply` fails with `no matches for kind "VaultSecret"` |

## Checking

```bash
# Is the operator installed in your vcluster? Both commands must find something.
kubectl get crd vaultsecrets.ricoberger.de
kubectl get deployment vault-secrets-operator -n vault-secrets-operator

# How often the operator reads Vault again, in seconds. 0: only when a VaultSecret changes.
kubectl get deployment vault-secrets-operator -n vault-secrets-operator \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="VAULT_RECONCILIATION_TIME")].value}{"\n"}'

# The status of your VaultSecrets, and the reason for a failure.
kubectl get vaultsecret -n my-namespace
kubectl describe vaultsecret my-app-db -n my-namespace

# The keys of the generated Secret and their sizes, without the values.
kubectl describe secret my-app-db -n my-namespace

# Read Vault again after a change there, then restart the pods that use environment variables.
kubectl delete secret my-app-db-env -n my-namespace
kubectl rollout restart deployment/my-app -n my-namespace
```

The upstream [README](https://github.com/ricoberger/vault-secrets-operator) documents templating
and the remaining VaultSecret fields. The operator's version differs between vclusters; the fields
on this page work in every installed version.
