# GitOps into a vcluster (Argo CD)

Argo CD runs inside your vcluster, watches a git repository and keeps your vcluster's objects in
line with it: a change merged in git is deployed without anyone running `kubectl apply`. Use it
for anything you deploy repeatedly or from CI. A personal kubectl login ends after 12 hours, so a
pipeline outside the cluster cannot push changes in; Argo CD pulls them from inside instead, and
no credential for your vcluster leaves it.

The platform team can install Argo CD in your vcluster, with the SLAC login. You can also install
it yourself, as cluster-admin of your vcluster. Either way it needs a
hostname on your vcluster's Ingress allowlist and a client in S3DF Dex, which only the platform
team can provide: see
[Your vcluster](../../basic/vcluster/README.md#features-and-allowlists-the-platform-sets) and
[Logging users in](../../basic/authentication/README.md).

## How Argo CD deploys into your vcluster

1. Argo CD runs in the namespace `argocd` of your vcluster. Its pods run on the host cluster like
   any other pods of yours.
2. Its repo server clones your repository. For repositories on the internet, such as GitHub, it
   goes through the [S3DF HTTP proxy](../../basic/networking/README.md#the-s3df-http-proxy), as
   the platform's own services do.
3. Its application controller renders the manifests, compares them with your vcluster and applies
   the differences through your vcluster's API, `https://kubernetes.default.svc`.
4. Your vcluster syncs the resulting pods, Services, Ingresses and other synced kinds to the host,
   where platform policies check them. Argo CD sees only your vcluster: a host rejection does not
   fail the sync (see [Mistakes](#mistakes-that-break-or-hide-a-deployment)).

## Argo CD from the platform team

Ask the platform team (s3df-help) to install Argo CD in your vcluster, and name the people who
should administer it. The platform team registers Argo CD's client in S3DF Dex and holds its
secret, which is why it does the installation.

| Item | What the platform sets up |
|---|---|
| Installation | The upstream Helm chart, in namespace `argocd` |
| URL | A path ending in `/argo-cd` on a SLAC hostname, for example `https://my-vcluster.slac.stanford.edu/argo-cd`, through an Ingress. The platform team tells you the URL |
| Login | Choose LOG IN VIA SLAC: Argo CD signs you in through S3DF Dex |
| Who may do what | The people you named are Argo CD admins, listed by email, `<username>@slac.stanford.edu`. Argo CD's default role is empty, so it gives no one else any permission |
| Version | Set by the platform team at each installation or upgrade; see [Checking](#checking) |

Argo CD's RBAC lists people by email because S3DF Dex's tokens carry no groups: a policy line for
a group never matches. To add or remove an admin, or to change another setting, ask the platform
team. Argo CD's own ConfigMaps (`argocd-cm`, `argocd-rbac-cm`, `argocd-cmd-params-cm`) are theirs:
they apply them again at every upgrade, which undoes edits made in your vcluster.

Everything that Argo CD deploys is yours: Applications, AppProjects and repository credentials.
For a private repository, add its credentials in the UI (Settings, Repositories), or as a Secret
labelled `argocd.argoproj.io/secret-type: repository` in `argocd`; see the upstream
[declarative setup](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#repositories).
Never commit that Secret to git.

## Installing Argo CD yourself

Install the upstream Helm chart, `argo/argo-cd`, into a namespace `argocd` in your vcluster. First
ask the platform team for a hostname on your Ingress allowlist and for a Dex client with the
redirect URI `<url>/auth/callback`, for example
`https://my-app.slac.stanford.edu/argo-cd/auth/callback` (see
[Requesting a client](../../basic/authentication/README.md#requesting-a-client)). Then set these
chart values:

| Value | Setting | What it is for |
|---|---|---|
| `global.env` | `HTTP_PROXY` and `HTTPS_PROXY` `http://sdfproxy.sdf.slac.stanford.edu:3128`, and `NO_PROXY` as in [the networking guide](../../basic/networking/README.md#the-s3df-http-proxy) plus `argocd-repo-server` | The repo server reaches git and Helm repositories on the internet. Argo CD's components call the repo server by its short name, which must not go to the proxy |
| `configs.cm.url` | `https://my-app.slac.stanford.edu/argo-cd` | Argo CD's public URL. It builds the login redirect URI from it |
| `configs.cm."oidc.config"` | `name: SLAC`, `issuer: https://dex.slac.stanford.edu`, `clientID: <client ID>`, `clientSecret: $argocd-oidc:client-secret`, `requestedScopes: ["openid", "profile", "email"]` | The login through S3DF Dex. `$argocd-oidc:client-secret` reads the key `client-secret` of the Secret `argocd-oidc` in `argocd`, which must carry the label `app.kubernetes.io/part-of: argocd` |
| `configs.rbac."policy.csv"` | One line per person: `g, <username>@slac.stanford.edu, role:admin`, or `role:readonly` | Who may do what. Dex sends no groups, so name people |
| `configs.rbac.scopes` | `"[email]"` | Matches the policy against the `email` claim. The chart's default, `[groups]`, matches nothing on S3DF |
| `configs.params."server.insecure"` | `true` | Public TLS ends at the F5, so Argo CD serves plain HTTP behind it |
| `configs.params."server.basehref"`, `configs.params."server.rootpath"` | `/argo-cd` | Serves Argo CD under a path, so the hostname can serve other applications as well |
| `server.ingress` | `enabled: true`, `ingressClassName: nginx`, `hostname: my-app.slac.stanford.edu`, `path: /argo-cd`, `tls: false` | Publishes the UI. See [Ingress](../../basic/ingresses/README.md) |
| `dex.enabled` | `false` | The chart's own Dex is not needed: Argo CD talks to S3DF Dex directly |

Put the client secret into the Secret `argocd-oidc` from Vault, not from git; see
[Secrets](../../basic/secrets/README.md). Upgrades are then yours as well: upstream supports only
the three newest minor releases of Argo CD with fixes.

## HTTPRoutes in Argo CD 3.1 and later

Argo CD 3.1 and later judge an HTTPRoute healthy only when its `status` lists a gateway. On S3DF,
the platform attaches a copy of your route to the gateway, so the route in your vcluster never
gets a status (see [HTTPRoutes](../../basic/httproutes/README.md)). Every Application with an
HTTPRoute then stays `Progressing`. Override the check in `argocd-cm`; with the Helm chart:

```yaml
configs:
  cm:
    resource.customizations.health.gateway.networking.k8s.io_HTTPRoute: |
      hs = {}
      hs.status = "Healthy"
      hs.message = "On S3DF only the platform's copy of the route has a status"
      return hs
```

With Argo CD from the platform team, ask them to add it. Test the hostname to see whether a route
is published.

## Applications

[`application.yaml`](application.yaml) deploys the manifests in `deploy/` of a git repository
into `my-namespace`, and keeps them in line with git.

| Field | Value | What it is for |
|---|---|---|
| `metadata.namespace` | `argocd`: apply with `-n argocd` | By default, Argo CD reads Applications only from its own namespace |
| `spec.project` | `default` | The AppProject. `default` allows every repository and destination |
| `spec.source.repoURL`, `targetRevision`, `path` | Your repository, branch or tag, and directory | What to deploy: plain manifests, a kustomization, or a Helm chart |
| `spec.destination.server` | `https://kubernetes.default.svc` | Your vcluster, the one Argo CD runs in |
| `spec.destination.namespace` | A namespace of your own, such as `my-namespace` | Where objects without `metadata.namespace` go. Never `default`: platform policy forbids Pods, Services and Ingresses there |
| `spec.syncPolicy.automated` | `prune: true`, `selfHeal: true` | Applies every change in git. `prune` deletes objects removed from git; `selfHeal` undoes changes made by hand |

Create the destination namespace first, as
[Your vcluster](../../basic/vcluster/README.md#namespaces) shows, or keep it in the repository.

## Examples

| File | What it shows |
|---|---|
| [`application.yaml`](application.yaml) | An Application that deploys `deploy/` of `https://github.com/my-org/my-app.git` into `my-namespace`, with automated sync |

The repository, `my-org/my-app`, stands for your own.

```bash
kubectl apply -n argocd -f application.yaml
```

## Mistakes that break or hide a deployment

| Mistake | Result |
|---|---|
| No `spec.destination.namespace`, or `default` | Objects without a namespace land in `default`. Their Pods, Services and Ingresses never reach the host, while Argo CD reports them `Synced` |
| An object the host rejects: a hostname not on your allowlist, a `NodePort` Service, a StorageClass your vcluster may not use | The object exists in your vcluster, so Argo CD reports `Synced`. Its health may stay `Progressing`, for example a claim that never binds. The reason is a `SyncError` event: see [Reading a rejection](../../basic/platform-policies/README.md#reading-a-rejection) |
| An Application outside the `argocd` namespace | Argo CD ignores it, unless it is set up for Applications in other namespaces |
| An HTTPRoute in Argo CD 3.1 or later, without the health override | The Application stays `Progressing`, published or not |
| `NO_PROXY` without `argocd-repo-server` | Argo CD's components send their calls to the repo server through the proxy, which cannot reach it |
| A group in `policy.csv` | It never matches: Dex sends no groups. Name people by email |
| Editing `argocd-cm` or `argocd-rbac-cm` of Argo CD from the platform team | The next upgrade undoes it. Ask the platform team |
| Repository credentials committed to git | Everyone who can read the repository has them. Add them in the UI, or keep them in Vault |
| A CI pipeline with a personal kubeconfig instead of Argo CD | It stops working 12 hours after the login. Let Argo CD pull from git |

## Checking

```bash
# SYNC STATUS and HEALTH STATUS of every Application.
kubectl get applications -n argocd

# Why an Application is not Synced or Healthy.
kubectl describe application my-app -n argocd

# Objects the host cluster rejected, which Argo CD cannot see.
kubectl get events -n my-namespace --field-selector reason=SyncError

# Argo CD's version.
kubectl get deployment -n argocd -l app.kubernetes.io/name=argocd-server \
  -o jsonpath='{.items[0].spec.template.spec.containers[0].image}{"\n"}'
```

The platform team has also installed the GitLab agent for Kubernetes in a vcluster; to use it
instead, ask the platform team (s3df-help). Upstream references: the [Argo CD documentation](https://argo-cd.readthedocs.io/en/stable/),
the [Application specification](https://argo-cd.readthedocs.io/en/stable/user-guide/application-specification/)
and the [Helm chart](https://github.com/argoproj/argo-helm/tree/main/charts/argo-cd).
