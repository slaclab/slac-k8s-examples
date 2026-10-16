# Getting traffic in and out of your workloads (Traefik, ingress-nginx, MetalLB, Cilium)

Traffic reaches your pods through one of four objects: a ClusterIP Service between your own
workloads, an HTTPRoute or an Ingress for a web application, or a LoadBalancer Service for any
other protocol. Traffic that leaves the cluster carries the address of your pod's node, and HTTP
and HTTPS to the internet can go through the S3DF HTTP proxy. This page helps you choose, and
explains what the platform does on the way in and on the way out. Each object has its own guide.

Several of these depend on settings the platform team (s3df-help) keeps for each vcluster: the
gateway switch for HTTPRoutes, the hostnames the vcluster may publish, the MetalLB pools it may
use, and network isolation. See
[Your vcluster](../vcluster/README.md#features-and-allowlists-the-platform-sets).

## Choosing a way in

| Traffic | Object | Clients use | TLS | Login | Guide |
|---|---|---|---|---|---|
| Between workloads in your vcluster | ClusterIP Service | `my-app.my-namespace.svc.cluster.local`, which resolves only inside your vcluster | Your application's | Your application's | [Services](../services/README.md), [DNS](dns/README.md) |
| A web application | HTTPRoute, on the S3DF Traefik gateway | `https://my-app.slac.stanford.edu` | At the F5 | S3DF login (s3df-authnz) with Coact groups, through annotations | [HTTPRoutes](../httproutes/README.md), [Middlewares](../httproutes/middlewares/README.md) |
| A web application in a vcluster without the gateway, or one that already has an Ingress | Ingress, on ingress-nginx | `https://my-app.slac.stanford.edu` | At the F5 | Vouch, through annotations: any user with a slac.stanford.edu address, no group checks | [Ingress](../ingresses/README.md) |
| Any other TCP or UDP protocol, for example a database for clients outside your vcluster | LoadBalancer Service (MetalLB) | An IP address from a MetalLB pool | Your application's | Your application's | [LoadBalancer Services](../services/README.md) |

Use an HTTPRoute for a new web application. The gateway is the successor to ingress-nginx, and
only HTTPRoutes get the s3df-authnz login with Coact groups. HTTPRoutes need the gateway switch,
which is off for a new vcluster: ask the platform team to turn it on. Ingresses work in every
vcluster. An application that logs users in itself works behind either: see
[Logging users in to your application](../authentication/README.md).

## How a web request reaches your pod

1. The client looks up the hostname. Its DNS record leads to one of two SLAC F5 load balancers:
   `lb01-sdf-k8s01-gw.slac.stanford.edu` for HTTPRoutes, `lb01-sdf-k8s01.slac.stanford.edu` for
   Ingresses.
2. The F5 terminates TLS with the SLAC wildcard certificate `*.slac.stanford.edu` and passes the
   request to the Traefik gateway or to ingress-nginx in the host cluster.
3. The gateway or ingress-nginx matches the hostname and path to your HTTPRoute or Ingress, runs
   the login check if there is one, and forwards the request to a ready pod behind your Service.
4. Your pod receives the request from the gateway or ingress-nginx, not from the client. The
   client's address is in the `X-Forwarded-For` header.

The platform keeps the public certificate and the public entry points in one place, so your
application can serve plain HTTP and needs no certificate of its own. A network isolation profile
that limits incoming traffic still admits the gateway and ingress-nginx; see
[Network isolation and NetworkPolicies](network-policies/README.md).

## Hostnames and DNS

All vclusters share the gateway and ingress-nginx, so each vcluster may publish only the hostnames
approved for it. Your vcluster has two lists, one for Ingresses and one for HTTPRoutes. Ask the
platform team (s3df-help) for the hostname and its DNS record together, and say whether an Ingress
or an HTTPRoute will serve it.

| Object | Hostname rules | A hostname not on the list |
|---|---|---|
| Ingress | Every rule has a `host`, and all rules of one Ingress use the same one. Write one Ingress per hostname | The host cluster rejects the Ingress, and `kubectl describe` shows a `SyncError` event |
| HTTPRoute | `hostnames` is required, and every hostname in it must be on the list | The route is never attached to the gateway, and nothing reports an error |

- **One entry point per hostname.** The DNS record sends a hostname to one load balancer, so
  Ingresses or HTTPRoutes serve it, never both. Moving an application from an Ingress to an
  HTTPRoute needs the hostname on the HTTPRoute list and a change to its DNS record.
- **One level below slac.stanford.edu.** The wildcard certificate covers
  `my-app.slac.stanford.edu`, not `my-app.sdf.slac.stanford.edu`. Ask the platform team before you
  choose any other name.
- **Not `k8s.slac.stanford.edu`.** A new vcluster's lists hold only this name, but it carries the
  login page and the API of every vcluster, and its DNS leads to ingress-nginx, so an HTTPRoute for
  it never receives traffic. Don't publish an application there.

## TLS

- Public TLS ends at the F5, for HTTPRoutes and Ingresses alike. An Ingress needs no `tls`
  section and no certificate. An HTTPRoute cannot bring one: the gateway's HTTPS listener belongs
  to the platform.
- A LoadBalancer Service passes the connection straight to your pods, with no F5 in front. TLS, if
  you need it, is your application's job: see [TLS certificates with cert-manager](../certificates/README.md).

## No NodePorts

The host cluster rejects Services of `type: NodePort`, and every LoadBalancer Service must set
`allocateLoadBalancerNodePorts: false`. A node port opens the Service on every node of the host
cluster, which all tenants share, and network policies cannot control traffic to it. The platform
also drops traffic from outside the cluster to ports 30000-32767, the node port range, on every
pod. Use a LoadBalancer Service instead. The other rules the host enforces are in
[Platform policies](../platform-policies/README.md).

## What is not offered

| You might want | Use instead |
|---|---|
| TCP or UDP through the gateway or ingress-nginx | A LoadBalancer Service. Both carry only HTTP and HTTPS |
| A Gateway of your own, a TLSRoute or a GRPCRoute | An HTTPRoute without `parentRefs`. The platform's gateway admits routes only from the platform's own namespaces, and the platform copies only HTTPRoutes and Middlewares there |
| A Traefik IngressRoute | An HTTPRoute, with [Traefik Middlewares](../httproutes/middlewares/README.md) if you need them. Your vcluster does not sync IngressRoutes |
| A NodePort Service | A LoadBalancer Service |

## Traffic out of your pods

| Destination | Source address the destination sees |
|---|---|
| Pods and Services in your vcluster | The pod's own address |
| Anything outside the cluster: SLAC networks such as `134.79.0.0/16`, or the internet | The address of the node the pod runs on. Through the [S3DF HTTP proxy](#the-s3df-http-proxy), the proxy's |
| A remote host that admits only a fixed address | A static address on a second network interface (Multus) |

Pod addresses (`192.168.0.0/16`) exist only inside the cluster, so Cilium replaces them with the
node's address on connections that leave it (masquerading). The platform runs no egress gateway,
so the address changes when the pod moves to another node, and a remote firewall rule for one
node's address breaks. For a fixed address, the platform team can give a pod a second interface
with a static address on a facility ingest network or the DMZ: see
[Secondary networks with Multus](../../advanced/multus-secondary-networks/README.md) and the worked
example [Fixed-IP egress through a socat proxy](../../advanced/outgoing-ingest-network-with-socat-proxy/README.md).

If your vcluster's outgoing isolation profile is `vcluster` or `isolated`, the platform's policies
let its pods reach, outside your vcluster, only DNS, a few platform services and the SLAC address
ranges `134.79.0.0/16` and `172.16.0.0/12`. See
[Network isolation and NetworkPolicies](network-policies/README.md).

### The S3DF HTTP proxy

The platform's own services reach the internet through the S3DF HTTP proxy,
`sdfproxy.sdf.slac.stanford.edu`, port 3128. To send your containers' HTTP and HTTPS requests to
the internet the same way, set these variables in each container that makes them.
[`configmap-http-proxy.yaml`](configmap-http-proxy.yaml) holds them, for `envFrom`.

| Variable | Value | What it is for |
|---|---|---|
| `http_proxy`, `HTTP_PROXY` | `http://sdfproxy.sdf.slac.stanford.edu:3128` | The proxy for `http://` URLs |
| `https_proxy`, `HTTPS_PROXY` | `http://sdfproxy.sdf.slac.stanford.edu:3128` | The proxy for `https://` URLs. The value starts with `http://`: the client opens a tunnel through the proxy, and TLS stays end to end |
| `no_proxy`, `NO_PROXY` | `localhost,127.0.0.1,::1,.svc,.cluster.local,10.0.0.0/8,192.168.0.0/16,172.16.0.0/12,134.79.0.0/16,.slac.stanford.edu` | Destinations reached directly: loopback, the cluster's Services (`10.0.0.0/8`) and pods (`192.168.0.0/16`), and SLAC networks |

- Set both spellings. Tools differ: curl, for example, ignores the uppercase `HTTP_PROXY`.
- `no_proxy` matches the end of the hostname as the URL writes it. A Service called by its short
  name, such as `http://my-db:8080`, matches nothing, so the request goes to the proxy, which
  cannot reach your Service by that name, and fails. `my-db.my-namespace` misses too. Use
  `my-db.my-namespace.svc`, or add the short name to `no_proxy`. Address ranges match only URLs that contain an IP address, and not every client
  supports them.
- HTTP clients read the variables. Database drivers and most other clients ignore them.
- Java ignores them too. Set `-Dhttp.proxyHost=sdfproxy.sdf.slac.stanford.edu -Dhttp.proxyPort=3128
  -Dhttps.proxyHost=sdfproxy.sdf.slac.stanford.edu -Dhttps.proxyPort=3128` in `JAVA_TOOL_OPTIONS`,
  and the direct destinations in `-Dhttp.nonProxyHosts`, separated by `|`, for example
  `localhost|*.svc|*.cluster.local|*.slac.stanford.edu`.
- Image pulls don't use the variables: the node pulls your images, not your container. See
  [Container images and pulls](../images/README.md).

## Examples

| File | What it shows |
|---|---|
| [`configmap-http-proxy.yaml`](configmap-http-proxy.yaml) | The proxy variables in a ConfigMap, in both spellings |
| [`deployment-http-proxy.yaml`](deployment-http-proxy.yaml) | A Deployment that loads them with `envFrom`. Its curl container stands in for your application |

The manifests set no namespace. Apply them to a namespace of your own with `-n`: platform policy
forbids the vcluster's `default` namespace, and [Your vcluster](../vcluster/README.md) shows how to
create one.

```bash
kubectl apply -n my-namespace -f configmap-http-proxy.yaml -f deployment-http-proxy.yaml
kubectl rollout status deployment/my-app -n my-namespace

# 200 from PyPI.
kubectl exec -n my-namespace deploy/my-app -- \
  curl -sS -o /dev/null -w '%{http_code}\n' https://pypi.org/simple/

# curl names the variable it used and opens a tunnel through the proxy:
# "Uses proxy env variable https_proxy == ..." and "CONNECT pypi.org:443".
kubectl exec -n my-namespace deploy/my-app -- \
  curl -sSv -o /dev/null https://pypi.org/simple/ 2>&1 | grep -E 'Uses proxy|CONNECT'
```

## Mistakes that break traffic in or out

| Mistake | Result |
|---|---|
| A Service of `type: NodePort` | The host cluster rejects it, so it never receives traffic |
| A LoadBalancer Service without `metallb.io/address-pool`, or without `allocateLoadBalancerNodePorts: false` | The host cluster rejects it, and `EXTERNAL-IP` stays `<pending>` |
| A hostname that is not on your vcluster's list | An Ingress is rejected with a `SyncError` event. An HTTPRoute is never attached to the gateway, and nothing reports an error |
| An HTTPRoute in a vcluster without the gateway switch | The route stays in your vcluster and receives no traffic |
| A DNS record that leads to the wrong load balancer: `lb01-sdf-k8s01` for an HTTPRoute, or `lb01-sdf-k8s01-gw` for an Ingress | Requests reach an entry point that has no route for the hostname, so they never reach your application |
| Publishing on `k8s.slac.stanford.edu` | Your paths share a hostname with every vcluster's API and login page. An HTTPRoute there receives nothing |
| A remote firewall rule that admits one node's address | It breaks when the pod moves to another node. Ask the platform team for a static address through Multus |
| A container port in 30000-32767 behind a LoadBalancer Service | Connections from clients outside the cluster are dropped: the platform drops their traffic to that range on every pod. Use a lower port |
| Proxy variables set, and in-cluster calls by short Service name | The calls go to the proxy and fail. Use full Service names, or add the short names to `no_proxy` |
| Only the uppercase proxy variables | curl, and other tools that read only the lowercase `http_proxy`, send `http://` requests directly, not through the proxy |

## Checking

```bash
# Your Services, Ingresses and HTTPRoutes.
kubectl get services,ingresses -n my-namespace
kubectl get httproutes -n my-namespace

# Why the host cluster rejected an object.
kubectl get events -n my-namespace --field-selector reason=SyncError

# Where a hostname leads: lb01-sdf-k8s01-gw.slac.stanford.edu for an HTTPRoute,
# lb01-sdf-k8s01.slac.stanford.edu for an Ingress.
dig +short my-app.slac.stanford.edu

# The application, from outside the cluster.
curl -s -o /dev/null -w '%{http_code}\n' https://my-app.slac.stanford.edu/
```

Upstream reference: [Kubernetes Services](https://kubernetes.io/docs/concepts/services-networking/service/),
[Gateway API](https://gateway-api.sigs.k8s.io/), and Cilium
[masquerading](https://docs.cilium.io/en/stable/network/concepts/masquerading/).
