# Middlewares for HTTPRoutes (Traefik)

A Traefik Middleware checks or changes a request on its way from the S3DF gateway to your
application: it can admit only some client addresses, strip a path prefix, set headers or limit
the request rate. Write the Middleware in your vcluster next to the HTTPRoute, and name it in one
of the route's `filters`. Use one when the check or change should happen at the gateway, before
your application sees the request.

Middlewares reach the gateway only if the platform team has turned on the gateway switch for your
vcluster, the same switch that HTTPRoutes need. It is off by default; ask the platform team
(s3df-help), and see
[Your vcluster](../../vcluster/README.md#features-and-allowlists-the-platform-sets). The route
itself follows [HTTPRoutes with S3DF login](../README.md): an approved hostname and no
`parentRefs`.

## How a Middleware reaches the gateway

Write the Middleware in the same namespace as the route. The platform does the rest:

1. The vcluster syncs the Middleware and the route to the host cluster, into `vcluster--<name>`,
   and renames the reference in the route to the synced Middleware.
2. Kyverno creates a Middleware in `gateway-system`, named
   `<vcluster>-x-<middleware>-x-<namespace>`, that applies yours.
3. In its copy of the route in `gateway-system`, Kyverno points the first two filters of each
   rule at those Middlewares.
4. If the route asks for the S3DF login, Kyverno appends the s3df-authnz filter after yours. Your
   Middlewares run first: an allowlist turns a client away before the login page.

The route that the gateway serves lives in `gateway-system`, and a route can name only Middlewares
in its own namespace, so the platform gives each of your Middlewares a counterpart there.

## Naming a Middleware in a route

| Field | Value | What it is for |
|---|---|---|
| `type` | `ExtensionRef` | Marks the filter as a reference to a Middleware |
| `extensionRef.group` | `traefik.io` | The Traefik API group |
| `extensionRef.kind` | `Middleware` | The Traefik Middleware kind |
| `extensionRef.name` | The Middleware's name, in the route's namespace | The platform renames it on the way to the gateway |

The platform renames references only in some places, so:

- Put Middlewares in the first two entries of a rule's `filters`. Built-in Gateway API filters,
  such as `RequestHeaderModifier`, take up positions too. The s3df-authnz filter that the
  platform appends does not count.
- Put them in the rule's `filters`, not in `backendRefs[].filters`.
- Keep `-x-` out of Middleware names, and keep the names to 49 characters or fewer. The platform
  reads the original name from the start of the synced name, up to the first `-x-`, and vcluster
  shortens long synced names.

## The client address in ipAllowList

Requests reach the gateway through the SLAC F5 load balancer, so the address the gateway sees is
the F5's, not the client's. The platform therefore sets `ipStrategy` on every Middleware that has
`ipAllowList`:

```yaml
ipAllowList:
  ipStrategy:
    excludedIPs:
      - 134.79.138.0/24   # the F5 load balancer
      - 192.168.0.0/16    # the cluster's pod network
```

Traefik then reads `X-Forwarded-For` from the right and checks the first address that is not in
these ranges: the client's. The gateway trusts that header only on requests that come from the
F5. The setting replaces any `ipStrategy` you write, including `depth`. Your copy in the vcluster
still shows what you wrote: the change is made on the host cluster.

A refused client gets 403. Set `rejectStatusCode` on the Middleware to answer with another code.

The platform changes only `ipAllowList`. A `rateLimit` or `inFlightReq` Middleware counts by the
remote address by default, which is the F5's for every client: set
`sourceCriterion.ipStrategy.excludedIPs` to the same two ranges yourself, as
[`middleware-ratelimit.yaml`](middleware-ratelimit.yaml) does. The gateway runs at least two
Traefik replicas, and each one counts requests on its own, so a client can get up to that many
times the limit you set.

## Examples

| File | What it shows |
|---|---|
| [`middleware-ipallowlist.yaml`](middleware-ipallowlist.yaml) | An `ipAllowList` that admits only SLAC networks |
| [`httproute-ipallowlist.yaml`](httproute-ipallowlist.yaml) | A route without login that uses it |
| [`httproute-ipallowlist-authnz.yaml`](httproute-ipallowlist-authnz.yaml) | The allowlist and the S3DF login; the login runs after the allowlist |
| [`middleware-strip-prefix.yaml`](middleware-strip-prefix.yaml) | Strips `/my-app` from the path before the request reaches the application |
| [`middleware-headers.yaml`](middleware-headers.yaml) | Security headers on every response |
| [`httproute-strip-prefix.yaml`](httproute-strip-prefix.yaml) | A route under `/my-app` with both Middlewares above, the most one rule can use |
| [`middleware-ratelimit.yaml`](middleware-ratelimit.yaml) | A rate limit for each client address |

The manifests set no namespace. Apply them to a namespace of your own with `-n`: platform policy
forbids the vcluster's `default` namespace. The routes send traffic to a Service `my-app` on port
8080 in the same namespace, as in [`../httproute.yaml`](../httproute.yaml). Each route is named
`my-app`: apply one of them. To use the rate limit, name `rate-limit` in a rule's `filters`, the
way the routes name their Middlewares.

## Mistakes that break a route or let clients through

| Mistake | Result |
|---|---|
| The gateway switch is off for your vcluster | The Middleware and the route never leave the vcluster. Ask the platform team |
| The Middleware in another namespace than the route | The gateway cannot find it, and the rule stops working |
| A Middleware in the third or a later entry of a rule's `filters` | Not renamed, so the gateway cannot find it, and the rule stops working |
| A Middleware in `backendRefs[].filters` | Not renamed: the same result |
| `-x-` in a Middleware name, or a name longer than 49 characters | The platform looks for a Middleware with the wrong name, so the gateway cannot find it |
| A `chain` Middleware that lists your other Middlewares | The platform does not rename the names inside a Middleware, so the gateway cannot find them. Name each Middleware in the route's `filters` instead |
| Your own `ipStrategy` in an `ipAllowList` | Replaced by the platform's |
| A `rateLimit` or `inFlightReq` without `sourceCriterion.ipStrategy` | Every client arrives with the F5's address, so all clients share one limit. Set `sourceCriterion.ipStrategy.excludedIPs` to the two ranges above |
| A Middleware that reads a Secret, such as `basicAuth` or `digestAuth` | The platform does not copy or rename the Secret for the gateway, so the gateway cannot read it |
| A `plugin` Middleware | Traefik plugins are not enabled on the gateway |

## Checking

```bash
kubectl apply -n my-namespace -f middleware-ipallowlist.yaml -f httproute-ipallowlist.yaml
kubectl get middlewares.traefik.io,httproutes -n my-namespace

# From a SLAC network: your application's answer, for example 200. From elsewhere: 403.
curl -s -o /dev/null -w '%{http_code}\n' https://my-app.slac.stanford.edu/
```

The route's `status` stays empty inside your vcluster, because only the platform's copy is
attached to the gateway. If a rule does not behave as expected, ask the platform team (s3df-help)
to check the route `<vcluster>-x-my-app-x-my-namespace` in `gateway-system`.

The gateway runs Traefik 3.7. Reference:
[Traefik HTTP middlewares](https://doc.traefik.io/traefik/v3.7/reference/routing-configuration/http/middlewares/overview/),
[Traefik and the Gateway API](https://doc.traefik.io/traefik/v3.7/reference/routing-configuration/kubernetes/gateway-api/).
