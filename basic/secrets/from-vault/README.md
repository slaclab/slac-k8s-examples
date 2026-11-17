# Secrets from Vault at deploy time (Makefile and kustomize secretGenerator)

A Makefile reads the values of one Vault secret with your own Vault login. A kustomize
`secretGenerator` turns them into a Kubernetes Secret, and `kubectl apply -k` creates it in your
vcluster together with the workload that uses it. This method works in every vcluster. Use it where
your vcluster has neither the External Secrets switch nor the vault-secrets-operator: the
[secrets overview](../README.md) compares the methods.

Deploying needs read access to the Vault secret, so only people who can read the secret can deploy
or change the application. This is the original S3DF convention, and it keeps every value out of
git.

## How `make apply` works

1. The Makefile checks that you are logged in to Vault and that `NAMESPACE` is not `default`, and
   stops if either check fails.
2. It reads each key in `SECRET_KEYS` from `SECRET_PATH` and writes it to `etc/.secrets/<key>`.
   Only your user can read the files, and [`.gitignore`](.gitignore) keeps them out of git. If a
   read fails, it deletes `etc/.secrets/` and stops.
3. `kubectl apply -k . -n my-namespace` runs kustomize. kustomize generates the Secret
   `my-app-db-<hash>` from the files, puts that name into the Deployment, and kubectl applies both
   to your vcluster.
4. The Makefile deletes `etc/.secrets/`, whether or not the apply succeeded.

The Secret changes only when you run `make apply` again: a change in Vault does not reach your
vcluster on its own. The name carries a hash of the values, so a changed value gives a new Secret
name, and the Deployment rolls out new pods that use it. With unchanged values, the name and the
pods stay. The old Secret stays too; delete it once the new pods run.

## Settings

Set these on the command line, for example `make apply NAMESPACE=my-namespace`:

| Variable | Default | What it is for |
|---|---|---|
| `SECRET_PATH` | `secret/my-facility/my-vcluster/my-app/db` | The Vault path, including the `secret/` mount. Keep it under your vcluster's path, `secret/<facility>/<vcluster>/` |
| `SECRET_KEYS` | `username password` | The keys to read. Each becomes a file in `etc/.secrets/` and a key in the Secret. List the same files in `kustomization.yaml` |
| `NAMESPACE` | `my-namespace` | The namespace in your vcluster. The Makefile refuses `default`: platform policy forbids it |
| `VAULT_ADDR` | `https://vault.slac.stanford.edu` | The S3DF Vault. The Makefile uses your environment's value if you have set one |

| Target | What it does |
|---|---|
| `make apply` | Reads the secrets, applies the directory, deletes the files |
| `make secrets` | Only reads the secrets into `etc/.secrets/`. Run `make clear-secrets` when you are done |
| `make clear-secrets` | Deletes `etc/.secrets/` |

## Examples

| File | What it shows |
|---|---|
| [`Makefile`](Makefile) | The `check`, `secrets`, `apply` and `clear-secrets` targets |
| [`kustomization.yaml`](kustomization.yaml) | A `secretGenerator` that makes the Secret `my-app-db` from `etc/.secrets/username` and `etc/.secrets/password` |
| [`deployment.yaml`](deployment.yaml) | A Deployment that uses the Secret as an environment variable and as files in `/etc/my-app/db` |
| [`.gitignore`](.gitignore) | Keeps `etc/.secrets/` out of git |

When you copy this directory into your own repository, keep its `.gitignore`, or add
`**/etc/.secrets/` to the repository's `.gitignore`.

## Running it

Run these on your workstation, with the Vault CLI and kubectl installed, your kubectl context set
to your vcluster, and the namespace created (see [Your vcluster](../../vcluster/README.md#namespaces)). To
write the values into Vault first, see the [secrets overview](../README.md#vault).

```bash
export VAULT_ADDR=https://vault.slac.stanford.edu
vault login -method=ldap    # add username=<SLAC username> if it differs from your local one

vault kv list secret/my-facility/my-vcluster/my-app    # entry names, without values
kubectl config current-context                        # must be your vcluster

make apply SECRET_PATH=secret/my-facility/my-vcluster/my-app/db NAMESPACE=my-namespace
kubectl rollout status deployment/my-app -n my-namespace

# After a later make apply with changed values: list the Secrets, and delete the old one.
kubectl get secret -n my-namespace
```

## Mistakes that break the apply or leave a stale value

| Mistake | Result |
|---|---|
| `make apply` without a Vault login, or with an expired one | The Makefile stops with `Not logged in to Vault` before it reads anything |
| A key in `SECRET_KEYS` that the Vault secret does not have | `vault kv get` fails, the Makefile deletes `etc/.secrets/` and stops. Nothing is applied |
| A file in `kustomization.yaml` that `SECRET_KEYS` does not write | kustomize stops with `evalsymlink failure` on the missing file. Nothing is applied |
| `kubectl apply -k .` without `make` | kustomize stops for the same reason. This is intended: the files exist only during `make apply` |
| A path without `secret/`, copied from an ExternalSecret | Vault answers with an error and the Makefile stops. The CLI path includes the mount |
| The kubectl context of another cluster | The Secret and the Deployment go to that cluster. Check `kubectl config current-context` first |
| Expecting the Secret to follow Vault | The Secret keeps the old value until the next `make apply` |
| `generatorOptions.disableNameSuffixHash: true` | The Secret keeps its name, so the Deployment does not roll out when a value changes. Environment variables keep the old value until the pods restart |
| `make secrets` without `make clear-secrets` | The values stay on disk in `etc/.secrets/` |
| Copying the directory without its `.gitignore`, or moving `etc/.secrets/` | Git no longer ignores the files, and a commit puts the values in git history. Change them in Vault |

## Checking

```bash
git check-ignore -v etc/.secrets/username    # must name a .gitignore rule

kubectl get secret -n my-namespace           # my-app-db-<hash>, one per applied set of values
kubectl rollout status deployment/my-app -n my-namespace

# The keys of the Secret the Deployment uses, and their sizes, without the values.
kubectl describe secret -n my-namespace \
  "$(kubectl get deployment my-app -n my-namespace -o jsonpath='{.spec.template.spec.volumes[0].secret.secretName}')"
```

The kustomize reference for
[`secretGenerator`](https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/secretgenerator/)
describes the other ways to generate keys.
