# Fixed-address egress through a relay (socat on Multus)

Some remote hosts admit connections only from addresses on their firewall's list. Your pods
normally connect out from the address of whatever node they run on, so they cannot be listed. This
guide puts one small relay pod, running `socat`, on a secondary network with a static address. Your
application stays on the normal pod network, on any node, with as many replicas as it needs, and
connects to the relay. The relay opens the connection to the remote host from its static address.

You need two things from the platform team (s3df-help) first: a secondary network that routes to
the remote host, and one address on it for the relay. Read
[Secondary networks with Multus](../multus-secondary-networks/README.md) before you start: this
guide builds on it and does not repeat it. For the settings the platform keeps per vcluster, see
[Your vcluster](../../basic/vcluster/README.md#features-and-allowlists-the-platform-sets).

## When you need this

| Situation | Use |
|---|---|
| The remote host admits only fixed addresses, and the application has several replicas, needs other nodes, or uses more than a little CPU and memory | This relay |
| The remote host admits only fixed addresses, and the application is a single small pod | Put the application itself on the secondary network: see [Secondary networks with Multus](../multus-secondary-networks/README.md) |
| The remote host admits S3DF's node addresses, or does not filter | Nothing: connect directly. See [Traffic out of your pods](../../basic/networking/README.md#traffic-out-of-your-pods) |
| HTTP or HTTPS to the internet | The [S3DF HTTP proxy](../../basic/networking/README.md#the-s3df-http-proxy) |

The relay exists because the platform runs no egress gateway: Cilium replaces a pod's address with
its node's address on every connection that leaves the cluster. Only a few nodes are attached to
the secondary networks, and they also carry the platform's load balancers, so the platform keeps
workloads there small and gives out one address per pod. A relay needs one address and almost no
resources, whatever the size of the application behind it.

## How it works

```
my-app pods (any node) --eth0--> Service my-app-relay --> relay pod --net1, 192.0.2.10--> db.example.org:5432
```

1. The client connects to the Service `my-app-relay` on port 5432, inside your vcluster.
2. `socat` accepts the connection on the relay pod's `eth0` and opens a new TCP connection to
   `db.example.org:5432`.
3. The secondary network's routes send that connection out through `net1`, from the relay's static
   address. The remote host sees that address.
4. `socat` copies bytes in both directions until either side closes.

`socat` relays at the TCP level and does not read the traffic. TLS stays end to end between your
client and the remote host, and the client still checks the server's certificate against the name
it connected to. That matters when you choose how the client finds the relay (see below).

The relay leaves through `net1` only for destinations in the network's routes. Check that the
remote host's address is in them before you ask for firewall rules: the
[networks table](../multus-secondary-networks/README.md#networks) lists the routes, and `ip route`
in the relay pod shows them exactly. A destination outside the routes leaves through `eth0` from the
node's address, and the remote firewall drops it.

## Getting an address

Ask the platform team (s3df-help) for one address for the relay, on the network that routes to the
remote host. Name your vcluster, the network, and the remote host and port. Never pick an address
yourself or copy one from an example: Multus does not check whether the address is free, and two
holders of one address break each other's traffic. The examples use `192.0.2.10`, a documentation
address (RFC 5737), as a placeholder: replace it, and keep the network's prefix length (`/24` for
`sdf-ad-ingest`).

Ask the owner of the remote host to admit the relay's address. That is separate from the platform.

## Settings

The relay in [`deployment-relay.yaml`](deployment-relay.yaml):

| Setting | Value | Why |
|---|---|---|
| Pod template annotation `k8s.v1.cni.cncf.io/networks` | `name`, `namespace: multus-system`, `ips` only | Multus has no `gateway` field: the network's routes decide what leaves through `net1` |
| `nodeSelector` and toleration | `edu.stanford.slac.sdf.k8s.networking.multus: enable` and the network's node label; `node-role.kubernetes.io/ext-load-balancer`, `Exists`, `NoSchedule` | Multus runs only on nodes with the first label, only nodes with the second are attached to the network, and those nodes carry that taint |
| `replicas`, `strategy.type` | `1`, `Recreate` | One address belongs to one pod. `RollingUpdate` would start a second pod with the same address during every rollout |
| `TCP4-LISTEN:...,bind=$(POD_IP),fork,reuseaddr` | Listens on the pod's `eth0` address only, one child process per connection | Without `bind`, the relay also listens on `net1`, and NetworkPolicies do not apply there: any host on the network could use your relay |
| `TCP4:$(DEST_ADDRESS):$(DEST_PORT)` | The remote host and port | The relay opens one connection to it for each client connection |

For several remote hosts, run one relay per host and port, each with its own Service. They can
share one address only if they run in one pod: add a container per destination, each listening on
its own port.

## How the client finds the relay

Point the client at the relay by DNS name. Do not use `hostAliases`: it needs an IP address, and
the Service's ClusterIP is assigned when the Service is created, so it changes when the Service is
re-created and the hard-coded entry then points at nothing.

**Connect to the Service name.** Set the client's host to `my-app-relay` (in another namespace,
`my-app-relay.my-namespace.svc.cluster.local`), as
[`deployment-client.yaml`](deployment-client.yaml) does. Use this when the client does not check
the server's hostname: plain TCP, or TLS without hostname verification.

**Keep the original name.** If the client verifies the server certificate (for example PostgreSQL
`sslmode=verify-full`), the name it connects to must be `db.example.org`. Make that name resolve to
the relay inside your vcluster: your vcluster's CoreDNS loads extra server blocks from the keys
ending in `.server` of the ConfigMap `coredns-custom` in `kube-system`.
[`configmap-coredns-custom.yaml`](configmap-coredns-custom.yaml) adds a block that rewrites
`db.example.org` to the relay Service. [DNS inside your vcluster](../../basic/networking/dns/README.md)
explains these blocks. Then:

- Set the client's host to `db.example.org`.
- Set the relay's `DEST_ADDRESS` to the remote host's IP address, not its name. The relay uses the
  same DNS, so the name now resolves to the relay itself, and the relay would connect to itself.
- Restart CoreDNS after each change to the ConfigMap: it does not reload the added blocks on its
  own.

The rewrite applies to every pod in your vcluster. If `coredns-custom` already exists, add your key
to it instead of replacing it.

## Examples

| File | What it shows |
|---|---|
| [`deployment-relay.yaml`](deployment-relay.yaml) | The relay: a static address on `sdf-ad-ingest`, the two node labels and the toleration, one replica and `Recreate`, `socat` bound to `eth0` |
| [`service-relay.yaml`](service-relay.yaml) | The ClusterIP Service `my-app-relay` in front of the relay |
| [`deployment-client.yaml`](deployment-client.yaml) | A client with two replicas on the normal pod network, pointed at the Service name, with no `hostAliases` |
| [`configmap-coredns-custom.yaml`](configmap-coredns-custom.yaml) | Optional: the CoreDNS rewrite that makes `db.example.org` resolve to the relay |

For another network, change the network name, the network node label and the prefix length together, from
the [networks table](../multus-secondary-networks/README.md#networks). Replace `db.example.org`,
port `5432` and `my-namespace` (in the rewrite) with your own.

The workload manifests set no namespace: apply them with `-n my-namespace`, because platform policy
forbids the vcluster's `default` namespace. Only the CoreDNS ConfigMap names its namespace,
`kube-system`, because CoreDNS reads it there. Leave everything else in `kube-system` alone.

## Restricting who uses the relay

The relay forwards for any pod that can reach its Service. If other workloads share your vcluster,
allow only your client pods to reach the relay with a NetworkPolicy. NetworkPolicies take effect
only in a vcluster where the platform has turned on network isolation: see
[Network isolation and NetworkPolicies](../../basic/networking/network-policies/README.md). They
apply to `eth0` only, which is why the relay listens there and not on `net1`.

## Mistakes that break the relay or the network

| Mistake | Result |
|---|---|
| An address you chose yourself, or copied from an example or another manifest | Two holders of one address on a production network: both lose traffic. Nothing warns you |
| A toleration without both node labels | The relay can land on a node without Multus or without the network, and starts without `net1`, silently |
| `replicas` above 1, or the default `RollingUpdate` | Two pods with one address, during every rollout or all the time |
| `hostAliases` with the Service's ClusterIP | Breaks silently when the Service is re-created |
| A remote host outside the network's routes | The relay connects from the node's address through `eth0`, and the remote firewall drops it |
| A `gateway` key in the annotation | Ignored. Only the network's routes decide what leaves through `net1` |
| `TCP4-LISTEN` without `bind=$(POD_IP)` | The relay also listens on `net1`, where no NetworkPolicy protects it |
| The CoreDNS rewrite with the remote host's name in `DEST_ADDRESS` | The relay resolves the name to its own Service and connects to itself |
| A client that verifies the certificate, pointed at `my-app-relay` | The TLS handshake fails: the certificate names `db.example.org`. Use the rewrite |
| A readiness or liveness probe on the relay port | Each probe opens a connection to the remote host |

## Checking

```bash
kubectl apply -n my-namespace -f deployment-relay.yaml -f service-relay.yaml -f deployment-client.yaml

# The relay runs on a node attached to the network, with net1 and your address.
kubectl get pods -n my-namespace -l app=my-app-relay -o wide
kubectl exec -n my-namespace deploy/my-app-relay -- ip addr show net1

# The remote host's address is reached "via <router> dev net1". "dev eth0" means it is not in the routes.
kubectl exec -n my-namespace deploy/my-app-relay -- ip route

# From the client: a TCP connection through the relay to the remote host.
kubectl exec -n my-namespace deploy/my-app -- nc -zv -w 5 my-app-relay 5432
kubectl logs -n my-namespace deploy/my-app-relay
```

For the rewrite:

```bash
kubectl apply -f configmap-coredns-custom.yaml
kubectl rollout restart deployment coredns -n kube-system

# db.example.org now resolves to the relay Service's ClusterIP.
kubectl get service my-app-relay -n my-namespace
kubectl exec -n my-namespace deploy/my-app -- nslookup db.example.org
kubectl exec -n my-namespace deploy/my-app -- nc -zv -w 5 db.example.org 5432
```

If `nc` connects but the relay's log shows a failed or timed-out connection to the remote host,
the remote firewall does not yet admit the relay's address, or the destination is not in the
network's routes. The upstream references are the
[socat manual](http://www.dest-unreach.org/socat/doc/socat.html), the CoreDNS
[rewrite plugin](https://coredns.io/plugins/rewrite/), and the
[Multus CNI](https://github.com/k8snetworkplumbingwg/multus-cni) repository.
