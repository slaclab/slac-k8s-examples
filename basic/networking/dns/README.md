# DNS inside your vcluster (CoreDNS)

Your vcluster runs its own CoreDNS in its `kube-system` namespace. Your pods use it to look up
Services and pods by name, and it forwards every other name to an outside resolver. You can add
your own rules to it with one ConfigMap, without the platform team.

DNS needs no switch. Network isolation is a per-vcluster setting (see
[Your vcluster](../../vcluster/README.md#features-and-allowlists-the-platform-sets)), and every
isolation profile lets your pods reach CoreDNS and lets CoreDNS reach any resolver, so lookups
work the same in all of them.

## How a lookup works

1. When the vcluster starts a pod with the usual `dnsPolicy: ClusterFirst`, it points the pod's
   resolver at your vcluster's `kube-dns` Service. The pod's `/etc/resolv.conf` then has that
   nameserver, the search domains `my-namespace.svc.cluster.local`, `svc.cluster.local` and
   `cluster.local`, and `options ndots:5`.
2. CoreDNS answers names under `cluster.local` from your vcluster's own API: your Services, pods
   and endpoints.
3. CoreDNS forwards every other name to the resolver of the host node it runs on.

The platform runs 3 CoreDNS replicas and asks for them on different nodes, so one failing pod
does not stop lookups.

| Setting | Value | Why |
| --- | --- | --- |
| Cluster domain | `cluster.local` | The Kubernetes default, so charts and operators work unchanged |
| Fallback to host cluster DNS | Off | Names under `cluster.local` come only from your vcluster; Services on the host and in other vclusters do not resolve |
| `AAAA` (IPv6) queries | Answered at once with no records | The cluster has no IPv6, so applications get no IPv6 address to wait on |
| Pod records | `pods insecure` | `192-0-2-10.my-namespace.pod.cluster.local` answers with `192.0.2.10`, as in upstream Kubernetes |
| Your own rules | Server blocks from the ConfigMap `coredns-custom` | You can extend DNS without the platform team changing the main configuration |

These are the settings of the platform's current vcluster version. A vcluster created on an
older version may still run the upstream configuration, which answers `AAAA` queries normally.
`kubectl get configmap coredns -n kube-system -o yaml` shows the configuration your vcluster runs.

## Names that resolve

| Name | From | Resolves to |
| --- | --- | --- |
| `my-app` | A pod in `my-namespace` | The Service `my-app` in `my-namespace` |
| `my-app.my-namespace` or `my-app.my-namespace.svc.cluster.local` | Any pod in your vcluster | The Service `my-app` in `my-namespace` |
| `my-app-db.my-namespace.svc.cluster.local`, an `ExternalName` Service | Any pod in your vcluster | A `CNAME` to the external hostname, which is then resolved outside |
| A Service on the host or in another vcluster | Your pods | Nothing (`NXDOMAIN`) |
| Any other hostname, such as `my-app.slac.stanford.edu` | Your pods | Whatever the outside resolver returns |

To reach a Service in another namespace of your vcluster, use `<service>.<namespace>`; the short
name finds only Services in the pod's own namespace. NetworkPolicies may still block the
connection: see [Network isolation and NetworkPolicies](../network-policies/README.md).

With `ndots:5`, a name with fewer than five dots, such as `pypi.org`, is first tried with each of
the three search domains. Each try gets a fast `NXDOMAIN` from CoreDNS, but if lookup time
matters, write the name with a trailing dot (`pypi.org.`), which skips the search domains. Your
own `dnsConfig.options` are not used under `ClusterFirst`: the vcluster sets `ndots:5` and drops
other options. Extra `dnsConfig.nameservers` and `dnsConfig.searches` are kept, after the
vcluster's own.

For a Service that should resolve to a name outside the cluster, create an `ExternalName`
Service ([service-externalname.yaml](service-externalname.yaml)). It gives your application a
stable in-cluster name, and the external hostname changes in one place.

## Your own rules (`coredns-custom`)

CoreDNS reads every key ending in `.server` from the ConfigMap `coredns-custom` in your vcluster's
`kube-system` namespace, and adds each key's content as extra server blocks. The ConfigMap is
optional and does not exist until you create it. As cluster-admin in your vcluster, you can
create it yourself.

Each server block names the zone it answers for, and the port `1053`:

```
my-zone.example.org:1053 {
    ...
}
```

CoreDNS listens on `1053`, and the `kube-dns` Service sends port 53 there. A block without a port
listens on 53, which nothing sends queries to, so it is never used. The main block already serves
`.:1053`, so a block of your own for `.` (all names) fails. CoreDNS sends each query to the block
with the longest matching zone, so make the zone as narrow as the names you change. A block
answers only with its own plugins: a name in your zone that no plugin in the block answers fails
to resolve.

[configmap-coredns-custom.yaml](configmap-coredns-custom.yaml) has two blocks:

- `my-app-internal.server` makes `my-app.slac.stanford.edu` resolve, inside your vcluster, to the
  ClusterIP of the Service `my-app` in `my-namespace`. Pods that call the application's public
  hostname then stay inside the cluster. The block needs its own `kubernetes cluster.local` line to
  look up the rewritten name. Use it only for names your vcluster serves. The Service must accept
  what clients send to the public hostname, such as HTTPS on port 443 with a certificate for that
  name, because the Ingress or gateway is no longer in between.
- `my-zone.server` sends every name under `my-zone.example.org` to one resolver, for a zone that
  the node's resolver does not serve. Replace `192.0.2.53`, a documentation address, with the
  resolver's real address from whoever runs the zone.

Apply the ConfigMap, then restart CoreDNS. The `reload` plugin would pick up the change on its
own, but only after the mounted file updates, and a broken block then shows only in the logs. A
restart applies the change at once and shows straight away whether CoreDNS accepts it:

```
kubectl apply -f configmap-coredns-custom.yaml
kubectl rollout restart deployment coredns -n kube-system
kubectl rollout status deployment coredns -n kube-system
```

If a block has an error, the new CoreDNS pods fail to start and the rollout stops. The rollout
stops at most one old pod at a time, so the other old pods keep serving. Check the logs (see [Checking](#checking)), fix the ConfigMap
and restart again.

To pin a name for one pod only, use `hostAliases` in the pod spec instead. It writes the pod's
`/etc/hosts`, so it needs a fixed IP address: a Service's ClusterIP changes if the Service is
deleted and re-created.

## Examples

| File | What it shows |
| --- | --- |
| [pod-dns-check.yaml](pod-dns-check.yaml) | A throwaway pod with `dig` and `nslookup` for testing lookups |
| [service-externalname.yaml](service-externalname.yaml) | An `ExternalName` Service that gives an external hostname an in-cluster name |
| [configmap-coredns-custom.yaml](configmap-coredns-custom.yaml) | `coredns-custom` with a block that points a public hostname at an in-cluster Service, and a block that forwards a zone to its own resolver |

```
kubectl apply -n my-namespace -f pod-dns-check.yaml -f service-externalname.yaml
```

The ConfigMap sets its own namespace, `kube-system`, because CoreDNS reads it only there.

## Mistakes that break name resolution

| Mistake | Result |
| --- | --- |
| Naming the ConfigMap anything other than `coredns-custom`, or creating it outside `kube-system` | CoreDNS never reads it; nothing reports this |
| A key that does not end in `.server` | The block is ignored |
| A server block without `:1053`, such as `my-zone.example.org {` | The block listens on port 53, which no query reaches |
| A block for `.:1053` | CoreDNS cannot start with it, because the main block already serves `.:1053` |
| A zone wider than the names you change, such as `slac.stanford.edu:1053` for one rewrite | Every other name in that zone stops resolving, unless the block also has a `forward` line |
| A `rewrite` block without `kubernetes cluster.local` | The rewritten name is not looked up, and the query fails |
| Changing `coredns-custom` without restarting CoreDNS | The change applies only after a delay, and an error in it shows only in the CoreDNS logs |
| Calling a Service in another namespace by its short name | `NXDOMAIN`: the short name searches only the pod's own namespace |
| Using a host Service name, or another vcluster's Service name | `NXDOMAIN`: only your vcluster's Services resolve |
| Setting `dnsConfig.options` such as `ndots` on a `ClusterFirst` pod | Ignored: the vcluster sets `ndots:5` |
| Expecting `AAAA` records | Empty answers: the cluster has no IPv6 |
| `hostAliases` with a Service's ClusterIP | Breaks when the Service is re-created and gets a new address |

## Checking

```
# Your vcluster's CoreDNS, its Service and its configuration.
kubectl get deployment,pods,service -n kube-system -l k8s-app=vcluster-kube-dns
kubectl get configmap coredns -n kube-system -o yaml
kubectl get configmap coredns-custom -n kube-system -o yaml

# CoreDNS errors, including a syntax error in coredns-custom.
kubectl logs -n kube-system -l k8s-app=vcluster-kube-dns --tail=50

# The resolver configuration a pod gets.
kubectl exec -n my-namespace dns-check -- cat /etc/resolv.conf

# A Service in the pod's namespace, a Service in another namespace, an ExternalName Service,
# and an outside name (with the my-app-internal block applied, this one returns my-app's ClusterIP).
kubectl exec -n my-namespace dns-check -- dig +search +short my-app
kubectl exec -n my-namespace dns-check -- dig +search +short my-app.my-namespace
kubectl exec -n my-namespace dns-check -- dig +short my-app-db.my-namespace.svc.cluster.local
kubectl exec -n my-namespace dns-check -- dig +short my-app.slac.stanford.edu.
```
