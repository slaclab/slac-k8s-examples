# LoadBalancer Services (MetalLB)

A Service of type `LoadBalancer` gives your workload an IP address on an S3DF network, so clients
outside your vcluster can connect to it. MetalLB assigns the address from the pool you name. Use it
for protocols other than HTTP, for example a database or a data stream. A web application gets a
hostname and a login in front of it from an [HTTPRoute](../httproutes/README.md) or an
[Ingress](../ingresses/README.md) instead. For traffic between workloads inside your vcluster, a
`ClusterIP` Service is enough.

Two per-vcluster settings decide what works for you. The facility ingest pools are reserved for the
vclusters the platform team approves for them. A network isolation profile for incoming traffic
other than `default` limits which clients reach your pods. The platform team (s3df-help) keeps
both; see [Your vcluster](../vcluster/README.md#features-and-allowlists-the-platform-sets).

## How a Service gets its address

Write the Service inside your vcluster. The platform does the rest:

1. The vcluster syncs the Service to the host cluster, as
   `<service>-x-<namespace>-x-vcluster--<name>` in the namespace `vcluster--<name>` (see
   [Names on the host](../vcluster/README.md#names-on-the-host)). Give that name when you ask the
   platform team about it.
2. Kyverno on the host checks the copy. A `LoadBalancer` needs the annotation
   `metallb.io/address-pool` and `allocateLoadBalancerNodePorts: false`; a `NodePort` is refused. A
   refused Service exists only in your vcluster: it never gets an address, and `kubectl describe`
   shows a `SyncError` warning with the reason.
3. MetalLB assigns an address from the pool, and the address syncs back to your Service as
   `EXTERNAL-IP`.
4. A MetalLB speaker on a node attached to the pool's network answers for the address (layer 2
   mode). All traffic for the address enters through that node, and Cilium forwards it to a ready
   pod of the Service, on any node.

## Service types

| Type | Use it for |
|---|---|
| `ClusterIP` (the default) | Traffic between workloads in your vcluster |
| `LoadBalancer` | Clients outside your vcluster. The value is exactly `LoadBalancer`: the API refuses `Loadbalancer` |
| `NodePort` | Not allowed. A node port receives traffic from any source on every node, and network policies cannot control it, so the host refuses these Services |

## Pools

Each pool belongs to one network, and only nodes attached to that network answer for its
addresses.

| Pool | Addresses | Who may use it |
|---|---|---|
| `sdf-services` | Private SLAC addresses, on the S3DF services network | Every vcluster. The default choice |
| `sdf-dmz` | Public SLAC addresses, on the DMZ network | Ask the platform team (s3df-help) before you put a service on a public address |
| `sdf-rubin-pub` | Public SLAC addresses, on Rubin's public network | As for `sdf-dmz` |
| `sdf-ad-ingest` | Private addresses on AD's ingest network | Only vclusters the platform team has approved for the pool |
| `sdf-cryoem-ingest` | Private addresses on CryoEM's ingest network | Only vclusters the platform team has approved for the pool |
| `sdf-rubin-ingest` | Private addresses on Rubin's ingest network | Only vclusters the platform team has approved for the pool |

An ingest pool puts your service on a facility's own network, so the platform reserves it for that
facility's vclusters. Use one only if the platform team has approved your vcluster for it.

Every pool hands out addresses automatically. Without the annotation, MetalLB could give your
Service an address from any pool, public or another facility's, so the host requires you to name
the pool.

## Settings

| Field | Value | What it is for |
|---|---|---|
| `spec.type` | `LoadBalancer` | Asks MetalLB for an address |
| Annotation `metallb.io/address-pool` | A pool from the table above | Required. Chooses the network. The legacy key `metallb.universe.tf/address-pool` does not satisfy the host's check |
| `spec.allocateLoadBalancerNodePorts` | `false` | Required. Kubernetes defaults it to `true`, which gives the Service a node port on every node; the host refuses that for the same reason as a `NodePort` |
| `spec.ports` | One entry per port, each with a `name` | A Service can mix TCP and UDP ports, for example `53/TCP` and `53/UDP` |
| Annotation `metallb.io/loadBalancerIPs` | One free address inside the pool | Optional. Asks for a specific address; see below |
| Annotation `metallb.io/allow-shared-ip` | Any key, the same on each Service | Optional. Lets separate Services share one address. They need the same key and no port and protocol in common, and either both use `externalTrafficPolicy: Cluster` or both select exactly the same pods. To be sure they get the same address, give them the same `metallb.io/loadBalancerIPs`. One Service with all the ports is simpler |
| `spec.loadBalancerSourceRanges` | A list of CIDRs | Optional. Only clients in these ranges reach the address from outside the cluster; see below |
| `spec.externalTrafficPolicy` | `Cluster` (the default) or `Local` | Whether the pod sees the client's address; see below |

## Fixed addresses

An address belongs to the Service object that holds it. Changing the Service in place, with
`kubectl apply`, keeps the address. Deleting the Service releases it, for example when a Helm
release is re-installed. Every pool hands out free addresses automatically, so the released
address can go to another Service, and your re-created Service can get a different one. DNS
records and firewall rules that point at the old address then break.

To ask for a specific address, set `metallb.io/loadBalancerIPs` next to the pool in
`metallb.io/address-pool`, as in [`loadbalancer-fixed-ip.yaml`](loadbalancer-fixed-ip.yaml).
MetalLB assigns the address only if it is inside the pool and free; otherwise the Service gets
none. You cannot see the pool's range or which addresses are taken from inside your vcluster, so
ask the platform team (s3df-help) for a free address. To get the current address back after a
re-creation, write it into the annotation before you delete the Service. For a DNS name for the
address, ask the platform team.

Don't use `spec.loadBalancerIP`. Kubernetes deprecates the field, and MetalLB reports an error for a
Service that sets both it and `metallb.io/loadBalancerIPs`: a new Service with both gets no
address. The vcluster copies `spec.loadBalancerIP` back from the
host copy, where a platform policy can write the assigned address into it, so a Service can carry
the field although you never wrote it. If a Service of yours uses the annotation, check for the
field and remove it (see [Checking](#checking)).

## Who can connect

`loadBalancerSourceRanges` limits the clients that reach the address from outside the cluster.
Cilium, which load-balances Services on the host, enforces it. It does not check traffic from pods
or nodes inside the cluster; for that, see
[Network isolation and NetworkPolicies](../networking/network-policies/README.md).

For SLAC networks only, use the ranges the platform uses in its own network policies:
`134.79.0.0/16` and `172.16.0.0/12`, as in
[`loadbalancer-source-ranges.yaml`](loadbalancer-source-ranges.yaml).

If your vcluster's network isolation profile for incoming traffic is `vcluster` or `isolated`, the
platform's network policies admit clients from outside the cluster to your pods only from those
same SLAC ranges, whatever the pool.

## Client addresses and failover

| `externalTrafficPolicy` | Which node answers for the address | What the pod sees |
|---|---|---|
| `Cluster` (the default) | A node attached to the pool's network | Not reliably the client's address: traffic that Cilium forwards to a pod on another node arrives from a node address |
| `Local` | Only a node on the pool's network that runs both a MetalLB speaker and a ready pod of the Service | The client's address. Speakers run only on the nodes the platform marks for MetalLB, and the platform does not place your pods on those nodes: while none of your ready pods runs on one, the address does not answer |

Use `Cluster` unless your application needs the client's address. Before you use `Local`, ask the
platform team (s3df-help) whether your pods can run on a node that announces your pool.

Layer 2 mode has three consequences for every pool:

- One node carries all inbound traffic for an address, so that node's link limits the Service's
  bandwidth.
- If that node fails, another node takes over the address. Most clients follow within a few
  seconds.
- The address answers only while the Service has at least one ready pod. Give the pods a readiness
  probe, as in [`deployment.yaml`](deployment.yaml).

## Examples

| File | What it shows |
|---|---|
| [`deployment.yaml`](deployment.yaml) | The backend: two nginx pods labelled `app: my-app`, with a readiness probe |
| [`clusterip-service.yaml`](clusterip-service.yaml) | `my-app` on port 8080 inside the vcluster; the backend of the HTTPRoute and Ingress examples |
| [`loadbalancer-service.yaml`](loadbalancer-service.yaml) | `my-app-lb` on `sdf-services`, with an address MetalLB picks |
| [`loadbalancer-fixed-ip.yaml`](loadbalancer-fixed-ip.yaml) | A fixed address in the pool. The file holds a documentation address; replace it with one the platform team gives you |
| [`loadbalancer-source-ranges.yaml`](loadbalancer-source-ranges.yaml) | Clients from SLAC networks only |

The manifests set no namespace. Apply them to a namespace of your own with `-n`: platform policy
forbids the vcluster's `default` namespace, and [Your vcluster](../vcluster/README.md) shows how to
create one. All four Services select the pods of `deployment.yaml`. Each LoadBalancer example takes
an address from the pool, so apply only the ones you need.

## Mistakes that break or expose a Service

| Mistake | Result |
|---|---|
| `type: Loadbalancer`, or another spelling | The vcluster's API refuses the manifest |
| No `metallb.io/address-pool`, or only `metallb.universe.tf/address-pool` | The host refuses the Service. It exists in your vcluster, but `EXTERNAL-IP` stays `<pending>` and `kubectl describe` shows `SyncError` |
| No `allocateLoadBalancerNodePorts: false` | The same: the host refuses the Service |
| `type: NodePort` | The same: the host refuses the Service |
| A misspelt pool name | No address. `kubectl describe` shows `AllocationFailed` with `unknown pool` |
| The ingest pool of another facility | Against platform policy: your service lands on that facility's network. Use `sdf-services`, or ask the platform team |
| A `metallb.io/loadBalancerIPs` address outside the pool, or already in use | No address. `kubectl describe` shows `AllocationFailed` |
| Both `spec.loadBalancerIP` and `metallb.io/loadBalancerIPs` | MetalLB reports `AllocationFailed` or `LoadBalancerFailed`, and a new Service gets no address. Keep only the annotation |
| Deleting and re-creating a Service without a fixed address | It can get a different address, and DNS records and firewall rules for the old one break |
| `172.16.0.0/8` in `loadBalancerSourceRanges` | It means `172.0.0.0/8`, which also covers public addresses outside SLAC. Write `172.16.0.0/12` |
| Relying on `loadBalancerSourceRanges` to keep out other workloads in the cluster | Not checked for traffic from inside the cluster |
| A `targetPort` between 30000 and 32767 | Clients outside the cluster can be refused: the platform denies outside traffic to that range on every pod, to keep node ports closed. Use another port |
| `externalTrafficPolicy: Local` with no ready pod on a node that announces the pool | The address does not answer |
| No ready pod | The address does not answer, although `EXTERNAL-IP` shows it |

## Checking

```bash
kubectl apply -n my-namespace -f deployment.yaml -f loadbalancer-service.yaml

# EXTERNAL-IP is <pending> until MetalLB assigns an address.
kubectl get service my-app-lb -n my-namespace

# Events: SyncError if the host refused the Service; IPAllocated or AllocationFailed from MetalLB;
# nodeAssigned when a node starts answering for the address.
kubectl describe service my-app-lb -n my-namespace

# The address answers only while at least one endpoint is ready.
kubectl get endpointslices -n my-namespace -l kubernetes.io/service-name=my-app-lb

# From a client outside your vcluster: 200 from nginx.
curl -s -o /dev/null -w '%{http_code}\n' http://<EXTERNAL-IP>:8080/

# Empty unless spec.loadBalancerIP is set. If it is, and you use metallb.io/loadBalancerIPs, remove it.
kubectl get service my-app-lb -n my-namespace -o jsonpath='{.spec.loadBalancerIP}{"\n"}'
kubectl patch service my-app-lb -n my-namespace --type=json \
  -p '[{"op": "remove", "path": "/spec/loadBalancerIP"}]'
```

To give a pod its own address on an ingest or DMZ network, rather than a Service address, see
[Secondary networks with Multus](../../advanced/multus-secondary-networks/README.md). The upstream
references are the MetalLB [usage guide](https://metallb.universe.tf/usage/) and
[layer 2 mode](https://metallb.universe.tf/concepts/layer2/) pages, and Cilium's
[kube-proxy replacement](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/)
page.
