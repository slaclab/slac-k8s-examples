# Secrets in your vcluster (Vault)

On S3DF, secret values such as passwords, tokens and keys live in Vault, and the Kubernetes
Secrets in your vcluster are made from Vault. There are three ways to make them: an
ExternalSecret, a VaultSecret, or a Makefile that you run when you deploy. This page compares the
three and helps you choose one. Whichever you use, no secret value goes into git: git holds Vault
paths and key names, and Vault holds the values, so any Secret can be made again from Vault.

Two of the methods exist only in some vclusters. The External Secrets integration is a
per-vcluster switch that the platform team sets, off by default, because each vcluster that uses it
needs its own Vault role and policy (see
[Your vcluster](../vcluster/README.md#features-and-allowlists-the-platform-sets)). The
vault-secrets-operator runs only in the vclusters where it has been installed. The Makefile works
in every vcluster.

## Vault

| Setting | Value | What it is for |
|---|---|---|
| Address | `https://vault.slac.stanford.edu` | `VAULT_ADDR` for the Vault CLI. Both operators below read this Vault too |
| Login | `vault login -method=ldap` | Logs you in with your SLAC username and password |
| Secrets engine | KV version 2, mounted at `secret/` | Holds the values |
| Your vcluster's path | `secret/<facility>/<vcluster>/`, for example `secret/my-facility/my-vcluster/my-app/db` | Keep your vcluster's secrets here. The External Secrets role of your vcluster reads below this path and in any path the platform team adds for it, and nowhere else, so secrets kept here keep working if you move to ExternalSecrets |

Write a value with the Vault CLI. If `vault kv put` or `vault kv list` on your path answers
`permission denied`, ask the platform team (s3df-help) for access.

```bash
export VAULT_ADDR=https://vault.slac.stanford.edu
vault login -method=ldap    # add username=<SLAC username> if it differs from your local one

# Read the password without echo, so it stays out of your shell history.
read -rs DB_PASSWORD
printf '%s' "$DB_PASSWORD" | \
  vault kv put secret/my-facility/my-vcluster/my-app/db username=my-app password=-
unset DB_PASSWORD

vault kv list secret/my-facility/my-vcluster/my-app    # entry names, without values
```

## The three methods

| Method | Available in | Reads Vault as | When the Secret changes |
|---|---|---|---|
| [ExternalSecret](external-secrets/README.md) (External Secrets Operator) | vclusters with the External Secrets switch | Your vcluster's own Vault role, from the host cluster | Every `refreshInterval`, 1 hour by default |
| [VaultSecret](vault-secrets-operator/README.md) (vault-secrets-operator) | vclusters where the operator is installed | An AppRole, from the operator inside your vcluster | Depends on how the operator is set up: on a timer, or only when the VaultSecret changes |
| [Makefile and kustomize](from-vault/README.md) | Every vcluster | You, with your own Vault login, on your workstation | Only when you run `make apply` again |

## Which method to choose

1. **ExternalSecret**, if your vcluster has the External Secrets switch; for a new application,
   ask the platform team for the switch first. The Secret follows changes in Vault, no Vault
   credential is stored in your vcluster or on a laptop, and deploying needs no Vault login, so
   Argo CD can apply the manifests.
2. **VaultSecret**, if your vcluster already runs the vault-secrets-operator and has no External
   Secrets switch, or if your manifests already use VaultSecrets. It also works with Argo CD. The
   operator keeps its Vault login in a Secret in your vcluster.
3. **Makefile**, in every other vcluster. Only people who can read the secret in Vault can deploy
   the application, so the Vault permission also controls who can change its configuration.

Once the Secret exists, a pod uses it the same way whichever method made it.

## How a Secret reaches a pod

The Secret lives in your vcluster, in the namespace of the pods that use it. The vcluster copies it
to your host namespace, `vcluster--<name>`, only when a pod or another synced object uses it,
because the kubelet that mounts it runs on the host cluster. Secrets that no pod uses stay in your
vcluster. An ExternalSecret's Secret goes the other way: the operator writes it on the host, and
the vcluster copies it into your namespace.

Everyone who can read Secrets in a namespace of your vcluster can read the values: see
[Logging in to your vcluster and who can do what](../vcluster/access/README.md).

## The same Vault entry, three ways

Each method writes the path of `secret/my-facility/my-vcluster/my-app/db` differently:

| Method | Field | Path |
|---|---|---|
| ExternalSecret | `spec.data[].remoteRef.key` | `my-facility/my-vcluster/my-app/db`, without the `secret/` mount |
| VaultSecret | `spec.path` | `secret/my-facility/my-vcluster/my-app/db`, without `data/`: the operator adds it |
| Makefile (`vault kv get`) | `SECRET_PATH` | `secret/my-facility/my-vcluster/my-app/db` |

## Keeping secret values out of git

- Keep values only in Vault. Git holds Vault paths and key names, never values.
- Don't commit a `kind: Secret` with `data` or `stringData`. Base64 is an encoding, not encryption.
- Don't put secret values in `secretGenerator` `literals`, ConfigMaps, `env` `value` fields, Helm
  values files or container arguments.
- Keep the Makefile's `etc/.secrets/` out of git. In your own repository, add `**/etc/.secrets/`
  to `.gitignore`, and check it with `git check-ignore -v`.
- If a value reaches git, change it in Vault and make the Secret again. Deleting the commit is not
  enough: clones, forks and history keep the old value.

## Mistakes that expose a secret or leave it stale

| Mistake | Result |
|---|---|
| Committing a Secret manifest, `etc/.secrets/` files, or `kubectl get secret -o yaml` output | The value is in git history. Change it in Vault |
| A `.gitignore` entry `etc/.secrets/` in the repository root, for files in a subdirectory | Not ignored: an entry with a `/` inside it matches only from its own directory. Use `**/etc/.secrets/` |
| Copying a path from one method to another without changing it | A VaultSecret or Makefile path without `secret/` cannot be read. An ExternalSecret key with `secret/` and the platform's store annotation gets a store that does not exist. Write each path as in the table above |
| Expecting a Secret from the Makefile to follow Vault | It keeps the old value until the next `make apply`. A VaultSecret's Secret follows Vault only if its operator reads Vault on a timer |
| A Secret in a different namespace from its pods | The pods don't start: `CreateContainerConfigError` for an environment variable, or a volume that never mounts |
| `vault.hashicorp.com/agent-inject` annotations on a pod | Nothing happens: the host cluster runs no Vault Agent injector. Use one of the three methods |
| Secrets outside `secret/<facility>/<vcluster>/` | The External Secrets role of your vcluster cannot read them, unless the platform team adds the path |

## Guides

| Directory | What it shows |
|---|---|
| [`external-secrets/`](external-secrets/README.md) | ExternalSecrets with the External Secrets Operator and Vault |
| [`vault-secrets-operator/`](vault-secrets-operator/README.md) | VaultSecrets with the vault-secrets-operator |
| [`from-vault/`](from-vault/README.md) | A Makefile and a kustomize `secretGenerator` that read Vault when you deploy |

For TLS certificates and their keys, see [TLS certificates with cert-manager](../certificates/README.md).

## Checking

```bash
# Is the vault-secrets-operator installed in your vcluster? Both commands must find something.
kubectl get crd vaultsecrets.ricoberger.de
kubectl get deployment vault-secrets-operator -n vault-secrets-operator

# The keys of a Secret and their sizes, without the values.
kubectl describe secret my-app-db -n my-namespace

# Why a pod waits for a Secret: read the events at the end.
kubectl describe pod -n my-namespace -l app=my-app
```

The platform team (s3df-help) can tell you whether your vcluster has the External Secrets switch.
