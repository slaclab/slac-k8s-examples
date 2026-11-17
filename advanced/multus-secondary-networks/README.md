# Secondary networks with Multus (static addresses on ingest and DMZ networks)

Multus gives a pod a second network interface, `net1`, with a static address on a facility ingest
network or on SLAC's DMZ, next to its normal interface `eth0`. Use it when a remote firewall admits
only known addresses, or when the workload has to sit on the network itself, as EPICS clients do.
For clients that connect in to a fixed address, a LoadBalancer Service is simpler: see
[LoadBalancer Services](../../basic/services/README.md).

Before you start, you need two things from the platform team (s3df-help): the network, and one
address on it for each pod. No feature switch is involved: the annotation reaches the host with
the pod in every vcluster. For the settings the platform does keep per vcluster, see
[Your vcluster](../../basic/vcluster/README.md#features-and-allowlists-the-platform-sets).

## How a pod gets its second interface

Your pod normally leaves the cluster with the address of the node it runs on, which changes when
the pod moves (see [Traffic out of your pods](../../basic/networking/README.md#traffic-out-of-your-pods)).
On `net1` the pod has its own address, which a remote firewall can admit. Write the annotation, a
node selector and a toleration on the pod template. The platform does the rest:

1. The vcluster syncs the pod, with its annotation, to the host cluster.
2. The host scheduler places the pod on a node that runs Multus and is attached to the network.
   Multus runs only on some nodes.
3. Multus creates `net1` as a macvlan interface on the node's link to the network. The pod gets its
   own MAC address and the address from your annotation, directly on that network.
4. Multus adds the network's routes to the pod. The destinations the network serves go out through
   `net1`, from your address. Everything else stays on `eth0`, including the default route,
   Services, DNS and the internet.

## Networks

The networks are defined on the host cluster, in its namespace `multus-system`, so your vcluster
does not show them. A NetworkAttachmentDefinition you create in your vcluster is not synced to the
host and has no effect.

| Network (`name`) | Network node label (value `"true"`) | Notes |
|---|---|---|
| `sdf-ad-ingest` | `edu.stanford.slac.sdf.networking/vlan832` | |
| `sdf-ad-ingest-static` | `edu.stanford.slac.sdf.networking/vlan832` | The same network and routes as `sdf-ad-ingest` |
| `sdf-cryoem-ingest` | `edu.stanford.slac.sdf.networking/vlan829` | |
| `sdf-dmz` | `edu.stanford.slac.sdf.networking/vlan834` | |
| `sdf-rubin-pub` | `edu.stanford.slac.sdf.networking/vlan857` | |

When the platform team gives your vcluster a network, it also gives you the subnet and its prefix
length, and an address. Hosts on that subnet are reached directly through `net1`. Traffic to other
destinations follows the network's routes, which the platform sets; whatever the routes don't
cover leaves through `eth0`, from the node's address. `ip route` in the pod shows the exact list
(see [Checking](#checking)).

The ingest networks serve the AD and CryoEM facilities, and `sdf-rubin-pub` serves Rubin; `sdf-dmz`
carries public SLAC addresses. Ask for the network your facility uses.

## Getting an address

Every network uses static addressing: there is no pool that hands out addresses, and a pod keeps
exactly the address its annotation names, which is what lets a remote firewall admit it. Ask the
platform team (s3df-help) for one address per pod. Name your vcluster, the network, and the
hosts the workload connects to. Never pick an address yourself or copy one from an example or
another manifest:

- The networks also carry routers, the nodes, LoadBalancer Service addresses and other vclusters'
  pods.
- Multus gives the pod whatever address the annotation names. It does not check whether a pod or
  a device already holds it, and two holders of one address break each other's traffic.

The examples use `192.0.2.10`, a documentation address (RFC 5737), where your address goes: replace
it, and keep the network's prefix length. Firewall rules on the remote side that admit your
address are a separate matter: arrange them with the owner of the remote host.

## The annotation

Put the annotation on the pod template (`spec.template.metadata.annotations`), not on the
Deployment's own `metadata`:

```yaml
k8s.v1.cni.cncf.io/networks: '[{"name": "sdf-ad-ingest", "namespace": "multus-system", "ips": ["192.0.2.10/24"]}]'
```

| Field | Value | What it is for |
|---|---|---|
| `name` | A network from the table | The network `net1` joins |
| `namespace` | `multus-system` | Where the networks are defined. Without it, Multus looks in your pod's host namespace, which has none |
| `ips` | `["<your-address>/<prefix>"]`, with the prefix length of the network's subnet | The address and subnet of `net1` |

The value is JSON inside a YAML string: keep the single quotes around it, and put no comments in
it. Multus has no `gateway` field and ignores a key of that name; the routes come from the network.

## Placing the pod

Multus runs only on nodes labelled `edu.stanford.slac.sdf.k8s.networking.multus: enable`, and only
nodes with the network's node label are attached to the network. Select both: a pod on any other
node starts without `net1`, and nothing reports an error. The nodes on these networks carry the
taint `node-role.kubernetes.io/ext-load-balancer:NoSchedule`, because they also answer for the
LoadBalancer addresses on these networks and the platform keeps general workloads off them.
Tolerate exactly that taint:

```yaml
nodeSelector:
  edu.stanford.slac.sdf.k8s.networking.multus: enable
  edu.stanford.slac.sdf.networking/vlan832: "true"
tolerations:
  - key: node-role.kubernetes.io/ext-load-balancer
    operator: Exists
    effect: NoSchedule
```

Without the toleration the pod stays `Pending`. Keep requests small, because these few nodes are
shared with the platform's load balancers and other vclusters' pods. Never tolerate every taint:
see [Node placement](../../basic/scheduling/README.md#never-tolerate-every-taint).

## One address, one pod

An address belongs to one pod at a time. Give each address its own Deployment with `replicas: 1`
and `strategy.type: Recreate`, so that Kubernetes stops the old pod before it starts the new one.
The default `RollingUpdate` starts the new pod first, so during every rollout two pods hold the same
address. For several pods, ask for several addresses and write one Deployment per address. A
StatefulSet cannot give its replicas different addresses, because they share one pod template.

## What `net1` does and does not do

- Connections out to the network's destinations leave through `net1`, from your address.
- Hosts on the network, and hosts in its routes, can connect to your address directly. Other
  clients cannot rely on it: the pod's replies to them leave through `eth0`, not `net1`.
- Services, Ingresses and HTTPRoutes reach the pod on `eth0`, never on `net1`.
- NetworkPolicies and the platform's network isolation apply to `eth0` only. On `net1`, the
  network's own firewall is the only filter, so a port your pod listens on is open to the network.

## Examples

| File | What it shows |
|---|---|
| [`deployment-static-ip.yaml`](deployment-static-ip.yaml) | One pod with an address on `sdf-ad-ingest`: the annotation on the pod template, the two node labels, the toleration, one replica and `Recreate`. It prints its interfaces and routes at start |

For another network, change the network name, the network node label and the prefix length
together, from the table. Two worked examples build on this guide:
[EPICS on the AD ingest network](../../kubernetes/overlays/dev/epics-example-app/README.md), and
[Fixed-address egress through a socat relay](../outgoing-ingest-network-with-socat-proxy/README.md),
which gives a whole application a fixed address through one small relay pod.

The manifest sets no namespace. Apply it to a namespace of your own with `-n`: platform policy
forbids the vcluster's `default` namespace.

## Mistakes that break a network or expose a workload

| Mistake | Result |
|---|---|
| An address you chose yourself, or copied from an example or another manifest | Two holders of one address on a production network: both lose traffic. Nothing warns you |
| `replicas` above 1, or the default `RollingUpdate`, with a static address | Two pods with one address, during every rollout or all the time |
| The annotation on the Deployment's `metadata` instead of the pod template's | The pod starts without `net1` |
| A toleration without both node labels | The pod can land on a node without Multus or without the network, and starts without `net1`, silently |
| The node labels without the toleration | The pod stays `Pending` |
| A prefix length other than the subnet's | `net1` gets the wrong subnet, and traffic through it fails |
| A `gateway` key in the annotation, to steer traffic | Ignored. Only the network's routes decide what leaves through `net1` |
| A destination that is not in the network's routes | The connection leaves through `eth0` from the node's address, and the remote firewall drops it |
| A Service, Ingress or HTTPRoute meant to reach the static address | They reach `eth0`. Clients on the network connect to the static address directly |
| Relying on NetworkPolicies to protect a port on `net1` | They do not apply there: every host the network's firewall admits can connect |

## Checking

```bash
kubectl apply -n my-namespace -f deployment-static-ip.yaml

# Running, on a node attached to the network. If it is Pending, the events name the taint or the selector.
kubectl get pods -n my-namespace -l app=my-app -o wide
kubectl describe pods -n my-namespace -l app=my-app

# net1 with your address and prefix; then the routes: "default via ... dev eth0", and the
# network's destinations "via <router> dev net1". The pod prints the same at start.
kubectl exec -n my-namespace deploy/my-app -- ip addr show net1
kubectl exec -n my-namespace deploy/my-app -- ip route
kubectl logs -n my-namespace deploy/my-app
```

If `ip addr show net1` reports that the device does not exist, the pod runs on a node without
Multus (check both node labels), or the annotation is not on the pod template. The upstream reference is the
[Multus CNI](https://github.com/k8snetworkplumbingwg/multus-cni) repository.
