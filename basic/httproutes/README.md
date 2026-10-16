# HTTPRoutes with S3DF login (s3df-authnz)

An HTTPRoute (Kubernetes Gateway API) publishes a web application on the S3DF Traefik gateway, the
successor to an Ingress on ingress-nginx. Four annotations on the route put the S3DF login in
front of the application, through the s3df-authnz service: whether a login is required, which
Coact groups may enter, and whether the application receives the user's token.

HTTPRoutes leave your vcluster only if the platform team has turned on the gateway switch for your
vcluster. The switch is off by default: without it, HTTPRoutes and Traefik Middlewares stay in your
vcluster and nothing is published. Ask the platform team (s3df-help) to turn it on; see
[Your vcluster](../vcluster/README.md#features-and-allowlists-the-platform-sets).

## How a route reaches the gateway

Write the HTTPRoute inside your vcluster with `hostnames` and `backendRefs` only, without
`parentRefs`. The platform does the rest:

1. The vcluster syncs the route to the host cluster.
2. If every hostname of the route is approved for your vcluster, Kyverno creates its copy in
   `gateway-system`, attached to the Gateway `traefik-system/traefik-gateway` (listener
   `websecure`), with `backendRefs` pointing at the synced Service.
3. If the route carries `.../required: "true"`, Kyverno also adds the s3df-authnz ForwardAuth
   filter after the rule's own filters, so every request is checked before it reaches your
   application.

The hostname must be one your vcluster is allowed to use, and its DNS must point at the gateway;
ask the platform team for both. The gateway is shared by all vclusters, so each vcluster may
publish only the hostnames approved for it:

- A route with a hostname that is not approved is not rejected. It syncs, but the platform never
  attaches it to the gateway, and nothing in your vcluster reports it. One unapproved hostname
  is enough to keep the whole route off the gateway.
- A route without `hostnames` is never published. Always set `hostnames`.
- The hostnames are checked when the route is created or changed. After the platform team
  approves a new hostname, delete the route and apply it again.

The gateway admits routes only from platform namespaces, so only the platform's copy in
`gateway-system` is attached to it. Your route's `status` therefore stays empty inside your
vcluster, published or not: test the hostname instead (see [Testing](#testing)).

To admit only some client addresses, strip a path prefix or set headers before a request reaches
your application, add Traefik Middlewares to the route: see
[Middlewares for HTTPRoutes](middlewares/README.md).

## Annotations

The prefix depends on the environment whose login stack protects the route:
`auth.sdf.slac.stanford.edu/` in production, `auth-dev.sdf.slac.stanford.edu/` in development.
The examples use the production prefix.

| Annotation (after the prefix) | Values | Default | What it is for |
|---|---|---|---|
| `required` | `"true"`, exactly | Absent: no login | Turns the S3DF login on for the route. Any other value leaves the route unprotected |
| `required-groups` | Comma-separated `facility:repo` patterns, for example `"rubin:production,rubin:dev"`; wildcards allowed: `"rubin:*"`, `"*:admin"`, `"*:*"` | Empty: every authenticated S3DF user | Restricts the route to users in these Coact groups |
| `groups-match-mode` | `"any"` or `"all"` | `"any"` | `any`: one matching group is enough. `all`: the user needs every listed pattern |
| `forward-user-credential` | `"true"` or `"false"` | `"false"` | Passes the user's own Dex token to the application in `X-Auth-Bearer`, so it can call other S3DF services as the user |

## What the application receives

After a successful check, the request reaches the application with these headers. The
application can trust them, because the gateway removes any copy a client sends.

| Header | Content |
|---|---|
| `X-Auth-Request-User` | The username |
| `X-Auth-Request-Email` | The email address |
| `X-Auth-Request-Groups` | The user's Coact groups, comma-separated `facility:repo` |
| `X-Auth-Request-Uid`, `X-Auth-Request-Primary-Gid`, `X-Auth-Request-Gids` | POSIX identity from Coact (production) |
| `X-Auth-Request-Czar-Facilities`, `X-Auth-Request-Pi-Repos`, `X-Auth-Request-Leader-Repos` | Coact roles, when the user has any (s3df-authnz 0.40.0 and later) |
| `X-Auth-Bearer` | `Bearer <Dex token>`, only with `forward-user-credential: "true"` |

Browsers log in through the S3DF login page and then carry a session cookie. Scripts and command
line tools send `Authorization: Bearer <token>` with a token from `s3df login`; both are checked
the same way.

## Examples

| File | Route |
|---|---|
| [`httproute.yaml`](httproute.yaml) | Public, no login |
| [`httproute-authnz.yaml`](httproute-authnz.yaml) | Any authenticated S3DF user |
| [`httproute-authnz-groups.yaml`](httproute-authnz-groups.yaml) | Only members of the listed Coact groups |
| [`httproute-authnz-forward-credential.yaml`](httproute-authnz-forward-credential.yaml) | Groups as above, and the application receives the user's token |

The manifests set no namespace. Apply them to a namespace of your own with `-n`: platform policy
forbids the vcluster's `default` namespace. Each route sends traffic to a Service `my-app` on port
8080 in its own namespace.

## Mistakes that leave a route open or broken

| Mistake | Result |
|---|---|
| A vcluster without the gateway switch | The route never leaves the vcluster, so nothing is published. Ask the platform team |
| A hostname that is not approved for your vcluster | The route is never published, and nothing reports an error. After the platform team approves the hostname, delete the route and apply it again |
| A route whose name and namespace together are longer than 46 characters | The route is never published, and nothing reports an error. Use a shorter name |
| `required-group` (singular), or another misspelt key | Ignored, so the route admits every authenticated user. A coming s3df-authnz release logs `... is an unknown annotation and has no effect` for it |
| `required: "yes"`, or any value other than `"true"` | No login at all. (`true` without quotes is not even accepted: annotation values must be strings, so `kubectl apply` refuses the manifest) |
| The production prefix on a route that should use the development login stack, or the reverse | The other environment's s3df-authnz protects the route, or none does |
| Several routes for one hostname with different `required-groups`, or stricter groups meant for one path | The policy is per hostname and ignores paths: one route's annotations win and the others are not enforced. Give an application with its own groups its own hostname |
| `forward-user-credential: "true"` without a need | The application and its request logs hold every visiting user's live token, which other S3DF services accept until it expires |

A new or changed route can answer 403 for up to 30 seconds, until s3df-authnz reads it.

## Testing

```bash
kubectl apply -n my-namespace -f httproute-authnz.yaml

# Without a login: 401 for a script (a browser is sent to the login page instead).
curl -s -o /dev/null -w '%{http_code}\n' https://my-app.slac.stanford.edu/

# With a token: 200, or 403 if you are not in the required groups.
s3df login
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer $(cat ~/.s3df-access-token)" https://my-app.slac.stanford.edu/
```

For the development stack, log in with `s3df login --dev` and send `$(s3df token --dev)` instead.
The full reference, including how to check which route supplies a hostname's policy, is
[TENANT-ONBOARDING.md](https://github.com/slaclab/k8s-auth/blob/main/docs/TENANT-ONBOARDING.md) in
the k8s-auth repository.
