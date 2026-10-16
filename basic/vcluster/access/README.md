# Logging in to your vcluster and who can do what (gangway, Dex, RBAC)

You reach your vcluster's Kubernetes API with kubectl and your SLAC account. Each vcluster has a
login page, run by gangway, that signs you in through Dex and prints the kubectl commands that set
up your kubeconfig. What you may do after that is decided by RBAC inside the vcluster: the
platform makes your vcluster admins cluster-admin, and the admins grant access to everyone else.

The list of vcluster admins is a per-vcluster setting that the platform team keeps; see
[Your vcluster](../README.md).

## How a login reaches your vcluster

1. You open `https://k8s.slac.stanford.edu/<name>`, the login page of vcluster `<name>`, and
   choose Sign In.
2. Dex (`https://dex.slac.stanford.edu`) sends you to the SLAC login.
3. The page prints `kubectl config` commands. They write your tokens, and the vcluster's OIDC
   client ID and secret, into your kubeconfig.
4. kubectl sends your ID token with every request to `https://k8s.slac.stanford.edu/api/<name>`.
   The platform's shared ingress forwards the request to your vcluster's API server.
5. The API server accepts only Dex tokens issued for its own client, `vcluster--<name>`, and takes
   your username from the token's email: `<username>@slac.stanford.edu`.

Every vcluster's API is a path on the shared host `k8s.slac.stanford.edu`, behind the platform's
ingress, so kubectl authenticates with a bearer token rather than a client certificate. Each
vcluster has its own Dex client, so a token from one vcluster's page is refused by every other.

## Logging in

kubectl is available on SLAC interactive nodes with `module load kubectl`; elsewhere, install it
yourself. Use a kubectl within one minor version of your vcluster's Kubernetes version, which
`kubectl version` shows.

```bash
module load kubectl                 # on a SLAC interactive node
# Open https://k8s.slac.stanford.edu/my-vcluster, sign in, and paste the commands it prints.
kubectl config current-context      # my-vcluster
kubectl auth whoami                 # Username  <username>@slac.stanford.edu
kubectl version                     # client and server versions
```

The commands write three kubeconfig entries:

| Entry | Value | What it is for |
|---|---|---|
| Cluster `<name>` | Server `https://k8s.slac.stanford.edu:443/api/<name>` | Your vcluster's API server, through the shared ingress |
| User | Auth provider `oidc`: issuer `https://dex.slac.stanford.edu`, client ID `vcluster--<name>`, client secret, ID token, refresh token | Your login. The client ID and secret are the same for everyone who uses this vcluster; the tokens are yours |
| Context `<name>` | The cluster and user above | Selects this vcluster for kubectl |

The cluster and context are named after the vcluster. If you use several vclusters, sign in on
each one's page and switch with `kubectl config use-context <name>`. Makefiles in this repository
that check `KUBECTL_DEPLOY_CONTEXT` before applying need this name: pass
`KUBECTL_DEPLOY_CONTEXT=<name>`.

`vcluster connect` does not work for tenants: it reads the vcluster's credentials from the host
cluster, where tenants have no access. Use the login page.

## How long a login lasts

Your ID token and your refresh token both expire 12 hours after you sign in, so kubectl cannot
renew the login. When it expires, kubectl fails to refresh the token: open the login page again
and paste the new commands, which replace the old tokens.

A personal login therefore does not suit CI pipelines or scheduled jobs. Run automation inside the
vcluster instead, for example with Argo CD; see
[GitOps into a vcluster](../../../advanced/gitops-argocd/README.md).

## Who can do what

Signing in proves who you are and grants nothing. Anyone who can complete the SLAC login can get a
token for any vcluster, so access comes only from RBAC inside the vcluster. A user with no binding
can only discover the APIs and check their own identity and permissions; every other request is
`Forbidden`.

### What the platform creates

The platform creates three ClusterRoleBindings in every vcluster:

| ClusterRoleBinding | ClusterRole | Subjects | What it is for |
|---|---|---|---|
| `vcluster-admins` | `cluster-admin` | Your vcluster admins, as listed by the platform team | Full control inside the vcluster: namespaces, CRDs, operators and RBAC |
| `cluster-admin` | `cluster-admin` | The group `system:masters` and the platform team's staff | Platform support; see [Platform staff access](#platform-staff-access) |
| `admin` | `admin` | None | Grants nothing |

vcluster admins are cluster-admin so they can install CRDs and operators and run their own RBAC
without the platform team. That power stays inside the vcluster: objects reach the host cluster
only through the vcluster's syncer, and the host's
[policies](../../platform-policies/README.md) still apply to them.

The platform creates no binding for the rest of your team: vcluster admins grant that themselves.
It re-applies the three bindings, and replaces their subjects, each time it applies your vcluster's
configuration. Don't edit them. To add or remove a vcluster admin, ask the platform team
(s3df-help).

### Granting access to teammates

vcluster admins grant access with RoleBindings (one namespace) and ClusterRoleBindings (every
namespace). Name each person as a subject of kind `User`, with the full SLAC email address. The
login carries no group memberships, so a `Group` subject for a Unix, Coact or other SLAC group
matches nobody: list the users.

Kubernetes ships these ClusterRoles for people:

| ClusterRole | With a RoleBinding in a namespace, the user can |
|---|---|
| `view` | Read most objects, but not Secrets, Roles or RoleBindings |
| `edit` | Create, change and delete most objects, read Secrets, and run pods as any ServiceAccount of the namespace. Not Roles or RoleBindings |
| `admin` | Everything `edit` can, plus Roles and RoleBindings, so the user can grant access to others in the namespace |

The custom resources of an operator appear in these roles only if the operator aggregates its
ClusterRoles into them. For anything narrower or different, write a Role, as in
`role-app-operator.yaml`.

## Examples

| File | What it shows |
|---|---|
| [`rolebinding-edit.yaml`](rolebinding-edit.yaml) | Two teammates who deploy in one namespace (`edit`) |
| [`rolebinding-view.yaml`](rolebinding-view.yaml) | Read-only access to one namespace (`view`) |
| [`clusterrolebinding-view.yaml`](clusterrolebinding-view.yaml) | Read-only access to every namespace |
| [`role-app-operator.yaml`](role-app-operator.yaml) | A Role that may restart Deployment `my-app` and read pods, logs and events, nothing more |
| [`rolebinding-app-operator.yaml`](rolebinding-app-operator.yaml) | Binds that Role to a teammate |

The Role and the RoleBindings carry no namespace: apply them with `-n`. The namespace must exist;
see [Your vcluster](../README.md).

```bash
kubectl apply -n my-namespace -f rolebinding-edit.yaml
kubectl auth can-i create deployments -n my-namespace --as my-colleague@slac.stanford.edu   # yes
kubectl auth can-i get secrets -n kube-system --as my-colleague@slac.stanford.edu          # no
```

## Platform staff access

- The platform team's staff are cluster-admin in every vcluster, through the `cluster-admin`
  binding, for support and operations.
- The platform also reaches your vcluster from the host cluster, with the vcluster's own admin
  credentials. It uses this to apply the bindings above.
- Everything your vcluster syncs to the host, including the Secrets and ConfigMaps your pods use,
  is stored in the host namespace `vcluster--<name>`, which platform staff administer.
- Your vcluster's API server writes an audit log of requests, which the platform collects.

## Mistakes that lock people out or let too many in

| Mistake | Result |
|---|---|
| A `User` subject without the domain, for example `my-colleague` | Matches nobody. The username is the full address, `my-colleague@slac.stanford.edu` |
| A `Group` subject for a Unix, Coact or other SLAC group | Matches nobody: the login carries no groups |
| A binding to the group `system:authenticated` | Grants everyone who can complete the SLAC login, not just your team |
| Editing `vcluster-admins`, `cluster-admin` or `admin` | The platform replaces their subjects the next time it applies your vcluster's configuration. Write your own bindings, and ask the platform team to change the admin list |
| `edit` for someone who must not see credentials | `edit` reads every Secret in the namespace, and can run a pod as any ServiceAccount there |
| `admin`, or a Role on all resources (`*`), when `edit` is enough | The user can write Roles and RoleBindings in the namespace and pass the access on |
| Committing or sharing your kubeconfig | Whoever has it acts as you in the vcluster until the tokens expire |
| `kubectl apply` with another vcluster's context selected | The objects go to that vcluster. Check `kubectl config current-context` first |
| A token from another vcluster's login page, or from `s3df login` | `error: You must be logged in to the server (Unauthorized)`: the API server accepts only tokens issued for its own client |
| A personal login in a CI pipeline | Stops working 12 hours after the sign-in |
| `vcluster connect`, or kubectl against the host cluster | Fails: tenants have no access to the host cluster |

## Checking

```bash
kubectl auth whoami                                      # your username and groups
kubectl auth can-i --list -n my-namespace                # what you may do in a namespace

# As a vcluster admin:
kubectl get clusterrolebinding vcluster-admins -o wide   # USERS: the vcluster admins
kubectl get rolebindings -n my-namespace -o wide         # who has access to the namespace
kubectl get clusterrolebindings -o wide                  # who has access to every namespace
kubectl auth can-i delete pods -n my-namespace --as my-colleague@slac.stanford.edu
```

To put a login in front of a web application rather than the Kubernetes API, see
[Logging users in to your application](../../authentication/README.md).

Upstream references: [Using RBAC Authorization](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
and [OpenID Connect tokens](https://kubernetes.io/docs/reference/access-authn-authz/authentication/#openid-connect-tokens).
