# Ingress (ingress-nginx)

An Ingress publishes an HTTP application from your vcluster under a SLAC hostname, through the
platform's shared ingress-nginx, behind a SLAC F5 load balancer that serves HTTPS. It is the older
of the two ways in for web traffic. For a new application, use an
[HTTPRoute](../httproutes/README.md), its successor, if your vcluster has the gateway switch; use
an Ingress where it does not, and for applications that already have one. For a login in front of
an Ingress, see [Vouch login](#vouch-login).

Every hostname must be on your vcluster's Ingress allowlist, which the platform team sets for each
vcluster: see
[Your vcluster](../vcluster/README.md#features-and-allowlists-the-platform-sets). For the other
ways into and out of the cluster, see [Getting traffic in and out](../networking/README.md).

## Ingress or HTTPRoute

| | Ingress (ingress-nginx) | HTTPRoute (Traefik gateway) |
|---|---|---|
| Available | In every vcluster | When the platform team turns the gateway on for your vcluster |
| S3DF login | Vouch: any user with a slac.stanford.edu address, no group checks | s3df-authnz: Coact groups, and optionally the user's token |
| Hostname allowlist | The Ingress allowlist | A separate HTTPRoute allowlist |
| DNS for the hostname | Alias (CNAME) of `lb01-sdf-k8s01.slac.stanford.edu` | Alias (CNAME) of `lb01-sdf-k8s01-gw.slac.stanford.edu` |

The upstream ingress-nginx project was
[retired in March 2026](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/): it
publishes no more releases or security fixes. The DNS record decides which of the two serves a
hostname, so a hostname is served by Ingresses or by HTTPRoutes, never both. See
[Moving to an HTTPRoute](#moving-to-an-httproute).

## How an Ingress reaches ingress-nginx

Write the Ingress inside your vcluster. The platform does the rest:

1. The vcluster syncs the Ingress to the host namespace `vcluster--<name>`, as
   `<ingress>-x-<namespace>-x-vcluster--<name>`, with each backend pointing at the host copy of
   your Service.
2. Kyverno sets `ingressClassName: nginx`, the class of the shared ingress-nginx, so every Ingress
   is served there.
3. Kyverno rejects the Ingress if a rule has no `host`, or if the hostname is not on your vcluster's
   allowlist.
4. The ingress-nginx admission webhook rejects the Ingress if another Ingress already serves the
   same hostname and path.
5. ingress-nginx serves the Ingress, and its `ADDRESS` fills in. These are addresses of the nodes
   that run ingress-nginx, not the address clients use.

If step 3 or 4 rejects the Ingress, it stays in your vcluster with an empty `ADDRESS`, and the
vcluster records a `SyncError` event on it with the reason. If the host refuses a change to an
Ingress it already serves, it keeps serving the previous version, and the `SyncError` event says
why.

Clients reach ingress-nginx through the F5 load balancer `lb01-sdf-k8s01.slac.stanford.edu`. It
presents the SLAC wildcard certificate `*.slac.stanford.edu` and terminates TLS, so an Ingress
needs no `tls:` block and no certificate. For the same reason, your
application never sees a client certificate, and clients never see a server certificate of yours.
An Ingress carries HTTP only. For mutual TLS or another protocol, use a
[LoadBalancer Service](../services/README.md).

## Hostnames

- **Only allowlisted hostnames.** All vclusters share one ingress-nginx, which merges Ingresses by
  hostname; the allowlist keeps one vcluster from serving another's hostname. Ask the platform
  team (s3df-help) to approve a hostname, and say that an Ingress will serve it: its DNS record
  must be an alias of `lb01-sdf-k8s01.slac.stanford.edu`.
- **Not `k8s.slac.stanford.edu`.** A new vcluster's allowlist holds only this hostname, but the
  platform reserves it for the login page (`/<name>`) and the API (`/api/<name>/`) of every
  vcluster. Don't publish an application there.
- **One hostname per Ingress.** The allowlist check needs every rule of an Ingress to use the same
  allowed hostname, so an Ingress with two hostnames is rejected even when both are allowed.
- **Every rule has a `host`.** On the shared ingress-nginx, a rule without one would catch
  requests for every hostname that has no Ingress of its own, so the host cluster rejects it.
- **One level below slac.stanford.edu.** The F5 serves only the wildcard certificate, which covers
  `my-app.slac.stanford.edu` but not `my-app.sdf.slac.stanford.edu`.

## Ingress settings

| Field | Value | What it is for |
|---|---|---|
| `ingressClassName` | `nginx` | The only class. The host cluster sets `nginx` whatever you write |
| `rules[].host` | One hostname from your allowlist, the same in every rule | Chooses the hostname. Required |
| `paths[].pathType` | `Prefix` for a plain path; `ImplementationSpecific` for a regular expression | `Prefix` and `Exact` are literal paths in Kubernetes |
| `backend.service` | The `name` of your Service, and its `port.number` or `port.name` | The Service in the Ingress's namespace that receives the requests |
| `tls` | Leave it out | TLS ends at the F5 |

## Annotations

ingress-nginx reads `nginx.ingress.kubernetes.io/` annotations on the host copy of the Ingress.

| Annotation (after the prefix) | Value | Default | What it is for |
|---|---|---|---|
| `proxy-read-timeout`, `proxy-send-timeout` | Whole seconds, no unit: `"300"` | `60` | Slow responses and long uploads |
| `proxy-body-size` | A size, for example `"500m"` | `100m` on this platform | Larger request bodies. A bigger request gets `413` |
| `backend-protocol` | `"HTTPS"` | `HTTP` | Your pod serves TLS itself. nginx does not verify the pod's certificate |
| `use-regex`, `rewrite-target` | See [Serving an application under a path](#serving-an-application-under-a-path) | | |
| `auth-url`, `auth-signin`, `auth-response-headers` | See [Vouch login](#vouch-login) | | |

Don't use snippet annotations (`configuration-snippet`, `server-snippet`, `auth-snippet`). Use
the annotations in the table above, or move the application to an
[HTTPRoute](../httproutes/README.md) with a [Middleware](../httproutes/middlewares/README.md).

ingress-nginx runs on the host cluster and resolves names there. The vcluster translates Secret
names in three annotations, `auth-secret`, `auth-tls-secret` and `proxy-ssl-secret`, to their host
copies, and passes every other annotation on unchanged. A URL in an annotation that points at a
Service in your vcluster, for example an `auth-url` for your own authentication service, must use
the host name of that Service:
`http://<service>-x-<namespace>-x-vcluster--<name>.vcluster--<name>.svc.cluster.local:<port>/...`.
If `<service>-x-<namespace>-x-vcluster--<name>` is longer than 63 characters, the vcluster shortens
it to 52 characters and a hash, so keep the names short enough.

## Serving an application under a path

[`ingress-with-auth-and-rewrites.yaml`](ingress-with-auth-and-rewrites.yaml) serves an application
at `https://my-app.slac.stanford.edu/my-app/` while the application sees requests for `/`. The path
`/my-app(/|$)(.*)` is a regular expression (so `pathType: ImplementationSpecific` and
`use-regex: "true"`), and `rewrite-target: /$2` passes on what follows `/my-app/`.

- nginx rewrites requests, not responses. Links the application writes must still start with
  `/my-app/`; many frameworks have a base-path setting for this.
- `use-regex` and `rewrite-target` apply to the whole hostname: every path on it, in every Ingress,
  becomes a case-insensitive regular expression. If other Ingresses use the hostname, check that
  their paths still match.

## Vouch login

Vouch is the platform's login service for Ingresses. It runs at `vouch.slac.stanford.edu`, logs
users in through the SLAC login (Dex), and keeps the session, for up to 15 hours, in the cookie
`slac-vouch` for the whole slac.stanford.edu domain, so one login covers every application behind
it. It admits any user whose email address is in slac.stanford.edu, and checks no groups. For
Coact groups, or for a new application, use an [HTTPRoute with s3df-authnz](../httproutes/README.md).
To log users in from inside your application instead, see
[Logging users in to your application](../authentication/README.md).

| Annotation (after `nginx.ingress.kubernetes.io/`) | Value | What it is for |
|---|---|---|
| `auth-url` | `"https://vouch.slac.stanford.edu/validate"` | nginx asks Vouch about every request |
| `auth-signin` | `"https://vouch.slac.stanford.edu/login?url=https://$http_host$request_uri"` | Sends a browser without a session to the login, then back to the page it asked for |
| `auth-response-headers` | `"X-Vouch-User"`; add `X-Vouch-IdP-Claims-Email` or `X-Vouch-IdP-Claims-Name` if the application needs them | The headers the application receives from Vouch |

For the development login stack, use `vouch-dev.slac.stanford.edu` in both URLs; it logs in through
the development Dex. The example needs no snippet annotation.

The application can trust only the headers listed in `auth-response-headers`, and only on requests
that come through ingress-nginx: nginx sets them from Vouch's answer and replaces any copy a client
sends. Every other request header comes from the client, so identity built from it can be
forged. A pod that reaches your Service
directly, without ingress-nginx, can send any header; to stop that, see
[Network isolation](../networking/network-policies/README.md).

Vouch also offers `X-Vouch-IdP-AccessToken`, `X-Vouch-IdP-RefreshToken` and `X-Vouch-IdP-IdToken`.
Never list them: the application, and anything that logs its request headers, would hold every
visitor's tokens. For the same reason, don't log or store request cookies: browsers send the
`slac-vouch` session cookie to every slac.stanford.edu site, yours included.

## Moving to an HTTPRoute

| Ingress | HTTPRoute |
|---|---|
| `rules[].host` | `hostnames` |
| `path: /`, `pathType: Prefix` | `matches[].path`, `type: PathPrefix` |
| `backend.service.name` and `port.number` | `backendRefs[].name` and `port` |
| The Vouch annotations | `auth.sdf.slac.stanford.edu/required: "true"`, and Coact groups if you want them |
| `X-Vouch-User` in the application | `X-Auth-Request-User` |
| `use-regex` and `rewrite-target` | A strip-prefix Middleware ([middlewares](../httproutes/middlewares/README.md)) |

1. Ask the platform team (s3df-help) for the gateway switch, if your vcluster does not have it, and
   to approve the hostname for HTTPRoutes.
2. Apply the HTTPRoute next to the Ingress. The Ingress keeps serving the hostname while its DNS
   record points at ingress-nginx.
3. Test the route through the gateway before DNS changes (see [Checking](#checking)).
4. Ask the platform team (s3df-help) for the hostname's DNS record to become an alias of `lb01-sdf-k8s01-gw.slac.stanford.edu`.
   Once `dig` shows the new alias, delete the Ingress.

## Examples

The examples are alternatives for one application, the Service `my-app` on port 8080, for example
[`../services/clusterip-service.yaml`](../services/clusterip-service.yaml) in front of
[`../services/deployment.yaml`](../services/deployment.yaml). Apply one of them.

| File | What it shows |
|---|---|
| [`ingress.yaml`](ingress.yaml) | Public, no login: one hostname, every path to one Service |
| [`ingress-timeouts-and-body-size.yaml`](ingress-timeouts-and-body-size.yaml) | Longer timeouts and a larger upload limit |
| [`ingress-with-auth-and-rewrites.yaml`](ingress-with-auth-and-rewrites.yaml) | Vouch login, and the application served under `/my-app/` |

The manifests set no namespace. Apply them to a namespace of your own with `-n`: platform policy
forbids the vcluster's `default` namespace, and [Your vcluster](../vcluster/README.md) shows how to
create one.

```bash
kubectl apply -n my-namespace -f ../services/deployment.yaml -f ../services/clusterip-service.yaml
kubectl apply -n my-namespace -f ingress.yaml
```

## Mistakes that break or expose an Ingress

| Mistake | Result |
|---|---|
| A hostname that is not on your vcluster's allowlist, for example one copied from another project | The host cluster rejects the Ingress: no `ADDRESS`, and a `SyncError` event with `Ingress denied for <name> - please contact s3df-help@slac.stanford.edu for approval` |
| Changing a served Ingress to a hostname that is not on the allowlist | The host keeps serving the previous version, and a `SyncError` event says why |
| Two hostnames in one Ingress | Rejected the same way, even when both are allowed. Write one Ingress per hostname |
| A rule without `host` | Rejected: `The Ingress host name must be defined, not empty.` |
| A hostname and path that another Ingress already serves | The webhook rejects it: `host "..." and path "..." is already defined in ingress ...` |
| A hostname below a subdomain, such as `my-app.sdf.slac.stanford.edu` | Browsers reject the F5's certificate, which covers only one level below slac.stanford.edu |
| `ingressClassName: traefik`, or any class other than `nginx` | Replaced with `nginx` on the host. For the Traefik gateway, write an HTTPRoute |
| A timeout with a unit, such as `"30s"` | Ignored, and the default applies. Write `"30"` |
| `client-max-body-size` | Not an ingress-nginx annotation, so it does nothing. Use `proxy-body-size` |
| `use-regex` or `rewrite-target` on a hostname that other Ingresses use | Their paths become regular expressions too, and their routing can change |
| A regular expression in a path with `pathType: Prefix` | Works on this platform's ingress-nginx, but newer releases reject it by default (`strict-validate-path-type`). Use `ImplementationSpecific` |
| An in-vcluster Service name, such as `my-auth.my-namespace.svc`, in `auth-url` | ingress-nginx looks the name up on the host, not in your vcluster, and requests fail. Use the host name of the Service |
| Identity from a header that is not in `auth-response-headers` | Any client can send that header and pose as any user |
| `X-Vouch-IdP-AccessToken`, `-RefreshToken` or `-IdToken` in `auth-response-headers` | The application and its logs hold every visitor's tokens, including refresh tokens, which obtain new access tokens |

## Checking

```bash
kubectl get ingressclass                          # nginx, the only class
kubectl get ingress my-app -n my-namespace        # ADDRESS fills in once ingress-nginx serves it
kubectl describe ingress my-app -n my-namespace   # see Events, at the end
kubectl get events -n my-namespace --field-selector reason=SyncError

dig +short my-app.slac.stanford.edu               # lb01-sdf-k8s01.slac.stanford.edu., then its address

# Public Ingress: the application's own status code.
curl -s -o /dev/null -w '%{http_code}\n' https://my-app.slac.stanford.edu/

# Vouch, without a session: 302 to https://vouch.slac.stanford.edu/login?url=...
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://my-app.slac.stanford.edu/my-app/

# While moving to an HTTPRoute: send the request to the gateway, whatever DNS says.
curl -s -o /dev/null -w '%{http_code}\n' \
  --connect-to my-app.slac.stanford.edu:443:lb01-sdf-k8s01-gw.slac.stanford.edu:443 \
  https://my-app.slac.stanford.edu/
```

References:
[ingress-nginx annotations](https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/),
[ingress-nginx path matching](https://kubernetes.github.io/ingress-nginx/user-guide/ingress-path-matching/),
[Vouch Proxy](https://github.com/vouch/vouch-proxy).
