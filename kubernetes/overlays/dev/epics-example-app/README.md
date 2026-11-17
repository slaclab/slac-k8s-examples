# EPICS clients on the AD ingest network (Multus)

EPICS clients find a channel by sending a search to a list of addresses, then connect to the
server (an IOC or a gateway) that answers. A pod on the normal pod network reaches outside hosts
only from its node's address, which changes when the pod moves. This example gives one EPICS
client pod a second interface, `net1`, with a static address on the AD ingest network
`sdf-ad-ingest`, so that the IOCs and gateways it talks to see one fixed address.

This example builds on [Secondary networks with Multus](../../../../advanced/multus-secondary-networks/README.md):
read it first. It explains the networks, their routes, the node labels and the toleration, and
does not repeat them here. Before you start, you need from the platform team (s3df-help) one
address on `sdf-ad-ingest` for the pod. For the settings the platform keeps per vcluster, see
[Your vcluster](../../../../basic/vcluster/README.md#features-and-allowlists-the-platform-sets).

## How it works

1. The Deployment runs one pod with the Multus annotation, the node labels and the toleration from
   the Multus guide. The pod gets `net1` with your address.
2. The pod reads its EPICS settings from a ConfigMap that kustomize generates from
   `epics-config.env`.
3. Searches and connections to addresses in the network's routes leave through `net1`, from your
   address. Everything else, including DNS and the rest of your vcluster, stays on `eth0`.

Check that the IOCs or gateways you need are in the routes of `sdf-ad-ingest` before you ask
anyone for firewall rules: see the
[networks table](../../../../advanced/multus-secondary-networks/README.md#networks), and run
`ip route` in the pod. A destination outside the routes is reached from the node's address through
`eth0`.

## EPICS settings

`epics-config.env` sets the variables that EPICS Channel Access (CA) and PV Access (PVA) clients
read. The example uses `198.51.100.20`, a documentation address (RFC 5737): replace it with the
addresses of the IOCs or gateways you connect to, which their owners give you.

| Variable | Value | Why |
|---|---|---|
| `EPICS_CA_ADDR_LIST` | Space-separated addresses, each optionally `:port` | Where CA clients send name searches. Without a port, the CA default `5064` applies |
| `EPICS_CA_AUTO_ADDR_LIST` | `NO` | Searches go only to the listed addresses, not to the broadcast address of every interface the pod has |
| `EPICS_PVA_ADDR_LIST` | Space-separated addresses, each optionally `:port` | Where PVA clients send name searches. Without a port, the PVA default `5076` applies |
| `EPICS_PVA_AUTO_ADDR_LIST` | `NO` | The same as for CA |

The pod gets the variables through `envFrom`. Kustomize adds a hash to the ConfigMap's name and
rewrites the reference, so a change to `epics-config.env` rolls out a new pod.

## Examples

| File | What it shows |
|---|---|
| [`kustomization.yaml`](kustomization.yaml) | The Deployment and a ConfigMap generated from `epics-config.env`. It sets no namespace |
| [`epics-example-app.yaml`](epics-example-app.yaml) | One EPICS client pod with an address on `sdf-ad-ingest`: the annotation on the pod template, the node labels, the toleration, one replica and `Recreate`. It prints its interfaces and routes at start |
| [`epics-config.env`](epics-config.env) | The EPICS client settings, with a placeholder address |

The image `ghcr.io/epics-containers/epics-base-runtime` contains the EPICS base tools, `caget`
among them, and `pvxget` from PVXS. Replace it with your own application image, and keep the
annotation, node selector, toleration, `replicas: 1` and `Recreate`. Replace `192.0.2.11` in the
annotation with your assigned address and keep the `/24`.

Apply the directory with `-k`, to a namespace of your own: platform policy forbids the vcluster's
`default` namespace.

## Mistakes that break the example

| Mistake | Result |
|---|---|
| An address you chose yourself, or copied from an example or another manifest | Two holders of one address on a production network: both lose traffic. Nothing warns you |
| `replicas` above 1, or the default `RollingUpdate` | Two pods with one address, during every rollout or all the time |
| An IOC or gateway outside the network's routes | Searches and connections leave through `eth0` from the node's address, and the remote firewall drops them: `caget` times out |
| `EPICS_CA_AUTO_ADDR_LIST` or `EPICS_PVA_AUTO_ADDR_LIST` left unset | Searches also go to the broadcast address of each interface, `net1` included, and so to every host on the ingest network |
| A `gateway` key in the annotation | Ignored. Only the network's routes decide what leaves through `net1` |
| `kubectl apply -f epics-example-app.yaml` instead of `-k .` | The ConfigMap is not created, and the pod stays in `CreateContainerConfigError` |

## Checking

```bash
kubectl apply -k . -n my-namespace

# Running, on a node attached to the network. If it is Pending, the events name the taint or the selector.
kubectl get pods -n my-namespace -l app=epics-example-app -o wide

# net1 with your address; the IOC or gateway addresses are reached "via <router> dev net1".
kubectl exec -n my-namespace deploy/epics-example-app -- ip addr show net1
kubectl exec -n my-namespace deploy/epics-example-app -- ip route

# The settings, then a read over CA and over PVA. Replace MY:PV:NAME with a PV you may read.
kubectl exec -n my-namespace deploy/epics-example-app -- env | grep '^EPICS_'
kubectl exec -n my-namespace deploy/epics-example-app -- caget MY:PV:NAME
kubectl exec -n my-namespace deploy/epics-example-app -- pvxget MY:PV:NAME
```

If `caget` reports that the channel did not connect, the server is not in `EPICS_CA_ADDR_LIST`,
it is outside the network's routes, or a firewall does not yet admit your address. The upstream
references are the [EPICS documentation](https://docs.epics-controls.org/) and the
[epics-containers](https://github.com/epics-containers) images.
