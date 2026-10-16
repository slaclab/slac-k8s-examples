# A PostgreSQL cluster with credentials from Vault (CloudNativePG and kustomize)

This overlay creates a two-instance CloudNativePG `Cluster` and the Secret that holds the
database owner's username and password, read from Vault on your workstation when you apply. Use
it as the starting point for a database whose credentials your team keeps in Vault. It needs the
CNPG operator in your vcluster: see [PostgreSQL in your vcluster](../../../../operators/cloudnativepg/README.md),
and [Secrets in your vcluster](../../../../basic/secrets/README.md) for the Vault flow and its
alternatives.

## How the Secret reaches the cluster

1. `make apply` reads the Vault path's `username` and `password` keys into `etc/.secrets/`, one
   file per key, readable only by you.
2. `kustomize` builds the `Secret` `exampledb-creds` (type `kubernetes.io/basic-auth`) from
   those files, without a name hash, and `kubectl apply` sends it with the `Cluster` to the
   namespace you name.
3. The Makefile deletes `etc/.secrets/` again, whether or not the apply succeeded.
4. The operator bootstraps the database `example` with owner `app`, sets the owner's password
   from the Secret, and runs `CREATE EXTENSION pg_sphere` in `example`. Because the Secret is
   named in `bootstrap.initdb.secret`, the operator does not create `example-db-app`: your
   application reads `exampledb-creds` instead, and connects to `example-db-rw`.

The `username` in Vault must be `app`, the `owner` in the `Cluster`; CNPG requires the two to
match. The `bootstrap` section is read only when the cluster is first created.

## Files

| File | What it shows |
|---|---|
| [`Makefile`](Makefile) | `make apply` (Vault to `etc/.secrets/` to `kubectl apply -k`) and `make dump` to see the result |
| [`kustomization.yaml`](kustomization.yaml) | The `Cluster` and the `secretGenerator` for `exampledb-creds`. It sets no namespace |
| [`cnpg-example-database.yaml`](cnpg-example-database.yaml) | The `Cluster`: a Rubin image with the `pg_sphere` extension, Weka data and WAL volumes, `Guaranteed` resources, memory and WAL parameters sized to them |

Apply it to a namespace of your own: platform policy forbids the vcluster's `default` namespace.

```bash
export VAULT_ADDR=https://vault.slac.stanford.edu
vault login -method=ldap
make apply NAMESPACE=my-namespace SECRET_PATH=secret/my-facility/my-vcluster/cnpg-example/exampledb

kubectl get cluster example-db -n my-namespace -w
kubectl get secret exampledb-creds -n my-namespace -o jsonpath='{.type}{"\n"}'   # kubernetes.io/basic-auth
```

Keep `etc/.secrets/` out of git (this repository's `.gitignore` already lists it) and never
redirect `make dump` into a committed file: its output contains the Secret.

## Mistakes that break the bootstrap

| Mistake | Result |
|---|---|
| A `username` in Vault other than `app` | The owner's password is not set from the Secret and the application cannot log in |
| `postInitSQL` instead of `postInitApplicationSQL` | `pg_sphere` is created in the `postgres` database, not in `example` |
| Changing `bootstrap` after the cluster exists | Nothing happens: `bootstrap` runs only once. Change the database with `psql` or a `Database` object |
| Adding `monitoring.enablePodMonitor` or a `prometheus.io/scrape` annotation | Deprecated, or scrapes the wrong ports. Write a `PodMonitor`, as in [`podmonitor-cluster.yaml`](../../../../operators/cloudnativepg/cluster/podmonitor-cluster.yaml) |
| `kubectl apply -k .` without the Makefile | kustomize stops: `etc/.secrets/username` is missing |
| `make apply` without `NAMESPACE` | The Makefile uses `my-namespace`, which you may not have. Pass your own |
