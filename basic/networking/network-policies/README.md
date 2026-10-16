# Network isolation and NetworkPolicies (Cilium)

The platform team gives each vcluster a network isolation profile. The profile decides what your
pods can reach, what can reach them, and whether the NetworkPolicies you write inside your
vcluster have any effect. Cilium enforces it on the host cluster.

Isolation is a per-vcluster setting, and you cannot see or change it from inside your vcluster.
A new vcluster has isolation on with the `default` profile in both directions; an existing
vcluster may differ. Ask the platform team (s3df-help) which profile your vcluster has, or to
change it; see [Your vcluster](../../vcluster/README.md#features-and-allowlists-the-platform-sets).

## How it works

1. The host cluster has a cluster-wide Cilium policy that allows all TCP and UDP traffic to and
   from every pod, except in host namespaces that are marked restricted. It is needed because the
   platform's cluster-wide ICMP and node port rules select every pod, and Cilium denies whatever
   the policies that select a pod do not allow.
2. Isolation on: the platform marks your host namespace `vcluster--<name>` restricted, which
   takes it out of that cluster-wide allow, and applies its own policies for your profile. Your
   vcluster syncs your NetworkPolicies to the host.
3. Isolation off: the platform applies no policies to your namespace, and your vcluster does not
   sync NetworkPolicies. The vcluster API still accepts them, including those that Helm charts
   and operators create, but they never reach the host and have no effect.

NetworkPolicies only ever add allowed traffic. A connection is allowed if any policy allows it,
the platform's or yours, so a NetworkPolicy cannot block traffic that the platform's policies
already allow. This is why NetworkPolicy sync is switched on together with isolation: without it,
the cluster-wide allow would make every NetworkPolicy meaningless.

## Profiles

With isolation on, the profile is set separately for incoming and outgoing traffic.

| Profile | Incoming traffic to your pods | Outgoing traffic from your pods |
|---|---|---|
| `default` | Everything | Everything |
| `vcluster` | From pods of your vcluster, and the baseline below | To pods of your vcluster, and the baseline below |
| `isolated` | The baseline below only | The baseline below only |

`vcluster` treats all namespaces of your vcluster as one: they all share one host namespace, so
pods in different namespaces of your vcluster can always talk to each other, and a NetworkPolicy
cannot narrow that. Under `isolated`, pods of your vcluster cannot talk to each other, even in the
same namespace, until a NetworkPolicy allows it. The only exceptions are the DNS and webhook ports
of the baseline below.

### The baseline

Under `vcluster` and `isolated`, the platform always allows the traffic that its own services
need, so that published routes, monitoring and logins keep working in every profile:

| Direction | Always allowed |
|---|---|
| Incoming | The gateway and ingress-nginx (host namespaces `gateway-system`, `traefik-system`, `ingress-nginx`), Prometheus (`prometheus-system`), clients on the SLAC networks `134.79.0.0/16` and `172.16.0.0/12`, and your vcluster's own pods and control plane on ports 53, 1053 and 10250 |
| Outgoing | Your vcluster's API server (ports 443 and 8443), DNS (your vcluster's CoreDNS and the host's), pods labelled `app: webhook` in your vcluster on port 10250, the platform namespaces above and `auth-system`, the SLAC networks `134.79.0.0/16` and `172.16.0.0/12`, and `dex.slac.stanford.edu` on port 443 |

Your vcluster's control plane pods (its API server, etcd and CoreDNS) are exempt from the profile,
and the baseline lets your pods reach the API server and DNS, so a profile can never cut your
vcluster off from its own API.

Under an `isolated` incoming profile, your vcluster's API server reaches your pods only on ports
53, 1053 and 10250. An admission webhook, such as an operator's, that listens on another container
port times out. Depending on the webhook's `failurePolicy`, the objects it checks are then
rejected or pass unchecked. A NetworkPolicy cannot fix this: it
can select only your own pods, not the control plane. Run the webhook on port 10250, or ask the
platform team (s3df-help) for a `vcluster` incoming profile.

Outside the baseline, a restricted outgoing profile blocks the internet, the pods and Services of
other vclusters, and other host services. Plan for that before you ask for isolation: package
installs, `git clone` from the internet and calls to external APIs from pods stop working until
a NetworkPolicy allows them. Image pulls are not affected, because the node pulls images, not
your pod.

### In every vcluster

| Rule | Why |
|---|---|
| Traffic from outside the cluster to ports 30000-32767 on any pod is dropped, whatever the profile or your NetworkPolicies say | This is the node port range; see [No NodePorts](../README.md#no-nodeports). A deny rule wins over every allow |
| ICMP (ping) is allowed to and from every pod | So `ping` working proves nothing about TCP or UDP |
| A blocked connection is dropped silently | The client hangs until it times out. A Service with no ready pods, by contrast, refuses the connection at once |
| Traffic on a second network interface (Multus `net1`) is not filtered | Isolation and NetworkPolicies apply to `eth0` only; see [Secondary networks with Multus](../../../advanced/multus-secondary-networks/README.md) |

## Writing NetworkPolicies

Write standard `networking.k8s.io/v1` NetworkPolicies in your namespaces. They matter only in a
vcluster with isolation on, and only for a direction whose profile is `vcluster` or `isolated`.
Under `default`, they are synced but restrict nothing.

- **No default-deny.** `isolated` already denies everything outside the baseline, and a
  default-deny NetworkPolicy cannot remove the baseline or what `default` and `vcluster` allow.
  Write only the allows you need.
- **Allow both ends.** A connection between two of your pods passes the sender's outgoing profile
  and the receiver's incoming profile. If both are `isolated`, you need an egress rule for the
  sender and an ingress rule for the receiver.
- **Don't allow DNS.** The baseline already allows it.
- **Selectors see only your vcluster.** Your vcluster rewrites every `podSelector` and
  `namespaceSelector` to select pods of your vcluster on the host. A `namespaceSelector` matches
  the labels of your vcluster's namespaces, such as `kubernetes.io/metadata.name`; an empty one
  means every namespace of your vcluster. You cannot select host namespaces or other vclusters.
- **`ipBlock` is for addresses outside the cluster.** It does not match pod addresses
  (`192.168.0.0/16`) or Service addresses. Select your own pods with `podSelector` instead.
- **Only NetworkPolicies.** Your vcluster does not sync CiliumNetworkPolicies, so rules by
  hostname (FQDN) or by HTTP path are not available. Use `ipBlock` with the address ranges of an
  external host.

## Examples

| File | What it shows |
|---|---|
| [`networkpolicy-allow-same-namespace.yaml`](networkpolicy-allow-same-namespace.yaml) | All pods of a namespace may talk to each other, in both directions. The first policy to add under `isolated` |
| [`networkpolicy-allow-from-namespace.yaml`](networkpolicy-allow-from-namespace.yaml) | Pods in another namespace of your vcluster may reach `app: my-app` on port 8080 |
| [`networkpolicy-allow-https-egress.yaml`](networkpolicy-allow-https-egress.yaml) | `app: my-app` may open HTTPS connections to any address outside the cluster, under a restricted outgoing profile |
| [`pod-netshoot.yaml`](pod-netshoot.yaml) | A throwaway pod with `curl`, `dig` and `nc` for testing what your pods can reach |

```bash
kubectl apply -n my-namespace -f networkpolicy-allow-same-namespace.yaml
```

## Mistakes that leave traffic open or blocked

| Mistake | Result |
|---|---|
| Relying on a NetworkPolicy in a vcluster with isolation off | It is accepted but never reaches the host. All traffic stays allowed |
| A default-deny NetworkPolicy under the `default` profile | No effect: the platform's policy allows everything, and allows add up |
| Expecting namespaces of one vcluster to be separated under `vcluster` | Pods of all your namespaces can always reach each other. Ask for `isolated` and allow paths with NetworkPolicies |
| Asking for a restricted outgoing profile without planning egress | Calls to the internet and other vclusters time out. Add an egress NetworkPolicy such as `networkpolicy-allow-https-egress.yaml` |
| An `ipBlock` with a pod or Service address | Matches nothing. Use `podSelector` and `namespaceSelector` |
| A `namespaceSelector` for a host namespace such as `ingress-nginx` | Matches nothing. The baseline already admits the gateway and ingress-nginx |
| An operator's admission webhook on a port other than 10250 under an `isolated` incoming profile | The API server cannot reach it. Objects it checks are rejected after a timeout, or pass unchecked |
| Under `isolated` in both directions, only an ingress rule on the server | The client's egress is still blocked, and the connection times out |
| Testing with `ping` | ICMP is always allowed, so the test says nothing about your application's port |

## Checking

```bash
# Your NetworkPolicies, with the selectors and ports of each.
kubectl get networkpolicy -n my-namespace
kubectl describe networkpolicy allow-same-namespace -n my-namespace

# Start the test pod, then try each kind of destination. -m and -w cap the wait, because
# blocked connections time out instead of being refused.
kubectl apply -n my-namespace -f pod-netshoot.yaml
kubectl exec -n my-namespace netshoot -- dig +short my-app.my-namespace.svc.cluster.local
kubectl exec -n my-namespace netshoot -- nc -zv -w 5 my-app.my-namespace.svc.cluster.local 8080
kubectl exec -n my-namespace netshoot -- curl -sS -m 5 -o /dev/null -w '%{http_code}\n' https://example.com
kubectl delete pod netshoot -n my-namespace
```

The test pod carries the label `app: netshoot`, so policies that select `app: my-app` do not
apply to it. To test a policy for `my-app`, run the same commands with `kubectl exec` in one of
its pods. If a connection your NetworkPolicies should allow still times out, ask the platform team
(s3df-help) to check your vcluster's profile and the dropped flows.
