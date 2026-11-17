# What the host enforces on your objects (Kyverno)

Kyverno on the host cluster checks the copy of each object that your vcluster syncs to the host.
It rejects copies that break a platform rule, fills in fields that depend on platform details,
deletes finished pods, and records privileged containers. The rules run on the host because you
are cluster-admin inside your vcluster, where any rule would be yours to remove. Read this guide
when an object you applied never starts, never gets an address, or behaves differently from what
you wrote.

Some rules depend on settings the platform team keeps for each vcluster: the Ingress hostname,
HTTPRoute hostname and StorageClass allowlists, and the gateway and External Secrets switches.
Rows marked "(gateway)" or "(External Secrets)" apply only when your vcluster has that switch.
[Your vcluster](../vcluster/README.md#features-and-allowlists-the-platform-sets) lists these
settings; ask the platform team (s3df-help) to change one.

## How an object reaches the host

1. You apply the object in your vcluster. Your vcluster's API server accepts it, so
   `kubectl apply` succeeds.
2. If the host must run it, the vcluster syncs a copy to your host namespace, `vcluster--<name>`,
   under a new name: pods, Services, Ingresses, PersistentVolumeClaims, the ConfigMaps and Secrets
   they use, and, with their switch, kinds such as HTTPRoutes and ExternalSecrets (see
   [What reaches the host cluster](../vcluster/README.md#what-reaches-the-host-cluster)).
   Deployments, StatefulSets, Jobs and CronJobs stay in your vcluster, so the pod rules apply to
   each pod they create.
3. Kyverno checks the copy each time the vcluster creates or changes it. It rejects a copy that
   breaks a rule, so the host never stores it. Other rules change the copy before the host stores
   it.
4. For a rejected copy, the vcluster records a `SyncError` warning event on your object and tries
   again later.

## Rejected

The host refuses a copy that breaks one of these rules. Your object stays in your vcluster without
a host copy; [Reading a rejection](#reading-a-rejection) shows where the error appears.

| Object | Rejected when | Policy in the error | Why |
|---|---|---|---|
| Pod | It has a `hostPath` volume, unless the platform team has made an exception for your vcluster | `enforce-k-disallow-pods-host-path-k-vclusters` | A host directory gives the pod the node's files and a way to escalate privileges. Use a PersistentVolumeClaim: see [Storage](../storage/README.md) |
| Service | Its type is `NodePort` | `enforce-k-disallow-services-nodeport-type-k-all` | A node port takes traffic from any source on every node, and a NetworkPolicy cannot control traffic to it. See [LoadBalancer Services](../services/README.md) |
| Service of `type: LoadBalancer` | It has no `metallb.io/address-pool` annotation | `enforce-k-disallow-service-empty-metallb-annotation-k-all` | Every pool hands out addresses automatically, so without the annotation the address could come from any pool, on any network. See [LoadBalancer Services](../services/README.md) |
| Service of `type: LoadBalancer` | `allocateLoadBalancerNodePorts` is not `false`. Kubernetes sets it to `true` when you leave it out | `enforce-k-disallow-lb-type-nodeport-k-all` | Node ports would open the Service on every node, as a NodePort does |
| Ingress | A rule has no `host` | `enforce-k-disallow-ingress-empty-host-k-all` | A rule without a host applies to requests for any hostname, on an ingress controller that every vcluster shares. See [Ingress](../ingresses/README.md) |
| Ingress | Its host is not on your vcluster's Ingress allowlist, or its rules use more than one host | `enforce-k-limit-ingress-k-<name>` | The ingress controller is shared, so each vcluster may serve only the hostnames approved for it. For a second hostname, write a second Ingress |
| PersistentVolumeClaim | Its `storageClassName` is not on your vcluster's StorageClass allowlist | `enforce-k-limit-storageclass-k-<name>` | Each class reaches particular storage, and the platform team decides which vcluster may use it. See [Storage](../storage/README.md) |
| Pod | It carries `edu.stanford.slac.sdf.project/usdf-embargo: "true"` or `edu.stanford.slac.sdf.project/rsp: "true"`, and your vcluster is not entitled to that node pool | `enforce-k-disallow-non-embargo-pods-k-embargo`, `enforce-k-disallow-non-rsp-pods-k-usdf-rsp` | These annotations place a pod on nodes reserved for Rubin services. See [Node placement](../scheduling/README.md) |

## Changed

The host changes its copy of these objects before storing it, so you don't need to set these
fields yourself. Your own `ingressClassName`, `ipStrategy` or `secretStoreRef` is replaced.

| Object | Change on the host copy | Why |
|---|---|---|
| Ingress | `ingressClassName` set to `nginx`, whatever you wrote | ingress-nginx, class `nginx`, is the host's only Ingress controller. See [Ingress](../ingresses/README.md) |
| Pod with a `nvidia.com/gpu` limit on a container in `containers` | Toleration `{key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}` added, unless the pod already tolerates that key | GPU nodes carry the taint to keep other pods off them, so the GPU limit is all you write. See [GPU workloads](../gpu/README.md) |
| Pod with the embargo or RSP annotation, in a vcluster entitled to that pool | The pool's toleration and a `nodeSelector` for the pool's nodes added | The pod runs only on the reserved nodes. See [Node placement](../scheduling/README.md) |
| HTTPRoute (gateway) | Published on the gateway only if every hostname is on your vcluster's HTTPRoute allowlist. With any other hostname the route stays unpublished, and no error appears. The s3df-authnz login filter is added when the route asks for a login | The gateway is shared, so each vcluster publishes only the hostnames approved for it. See [HTTPRoutes](../httproutes/README.md) |
| Traefik Middleware with `ipAllowList` (gateway) | `ipAllowList.ipStrategy` replaced by one that skips the addresses of the SLAC F5 load balancer and of the pod network | The allowlist then checks the client's address, not the load balancer's. See [Middlewares](../httproutes/middlewares/README.md) |
| ExternalSecret annotated `edu.stanford.slac.sdf.secrets/s3df-vault: "true"` (External Secrets) | `secretStoreRef` set to the ClusterSecretStore `<facility>-<name>` that the first two segments of `spec.data[0].remoteRef.key` name | You read Vault through your vcluster's own store without naming it. See [External Secrets](../secrets/external-secrets/README.md) |

## Deleted

| Object | When | Why |
|---|---|---|
| Pod in phase `Succeeded` or `Failed` | At the cleanup that runs every 15 minutes, once the pod is more than 10 minutes old. Age counts from the pod's creation, not from when it finished, so a short pod goes 10 to 25 minutes after it is created | Finished pods don't pile up on the host. Save what you need from a finished pod soon after it ends: see [Jobs and CronJobs](../jobs/README.md) and [Logs](../logging/README.md) |

The pod disappears from your vcluster too, and `kubectl logs` and `kubectl describe` no longer
work for it.

## Audited

| Object | What happens | Why |
|---|---|---|
| Pod with a privileged container: `securityContext.privileged: true` on a container, init container or ephemeral container | The host records it in a policy report for the platform team | Privileged mode disables most of a container's security mechanisms. Avoid it, and ask the platform team (s3df-help) before a workload depends on it |

## Pod security

Your pods share nodes with other tenants' pods. Don't run privileged containers or use the host's
namespaces (`hostNetwork`, `hostPID`, `hostIPC`); `hostPath` volumes are rejected. Set
`runAsUser`, `runAsGroup` and `fsGroup` to match the files your pod needs, for example on an
[S3DF filesystem](../storage/sdf-filesystem/README.md).

The platform sets no quota, so set requests and limits on every container: see
[Requests and limits](../resources/README.md).

## The default namespace

Platform policy forbids Pods, Services and Ingresses in your vcluster's `default` namespace.
`default` is where an object lands when a manifest or a command forgets its namespace, so keeping
it empty keeps every workload in a namespace you chose. Create a namespace for each application
([Your vcluster](../vcluster/README.md#namespaces) shows how) and pass it with `-n`; the examples
leave `metadata.namespace` unset for that reason. Leave `kube-system` to your vcluster's own
components: it runs your vcluster's DNS.

## Reading a rejection

A rejected object looks normal to `kubectl apply` and `kubectl get`, but nothing on the host serves
it:

| Object | What you see |
|---|---|
| Pod | `Pending`, on no node. For a Deployment, StatefulSet or Job, every pod it creates |
| PersistentVolumeClaim | `Pending`. Pods that use it don't schedule: their events say `persistentvolumeclaim "my-app-data-x-my-namespace-x-vcluster--my-vcluster" not found`, with the claim's host name |
| LoadBalancer Service | `EXTERNAL-IP` stays `<pending>` |
| Ingress | `ADDRESS` stays empty |

The reason is in a `Warning` event with reason `SyncError` on the rejected object, in its
namespace. For a pod that a Deployment makes, look at the pod, not the Deployment:

```bash
kubectl get events -n my-namespace --field-selector reason=SyncError
kubectl describe pvc my-app-data -n my-namespace     # the events are at the end
```

The message names the policy and the rule that rejected the copy, followed by the policy's
message:

```text
Error syncing to host cluster: create object: admission webhook "validate.kyverno.svc-fail" denied the request:

resource PersistentVolumeClaim/vcluster--my-vcluster/my-app-data was blocked due to the following policies

enforce-k-limit-storageclass-k-my-vcluster:
  allowed-storageClasses: 'validation error: Allowed storageClasses at vcluster--my-vcluster.
    rule allowed-storageClasses[0] failed at path /spec/storageClassName/ ...'
```

Policy names follow `<action>-k-<what>-k-<scope>`:

- `enforce-k-limit-ingress-k-<name>`, `enforce-k-limit-storageclass-k-<name>` and
  `enforce-k-limit-httproutes-k-<name>` hold your vcluster's allowlists. Use a value that is on
  the list, or ask the platform team (s3df-help) to add one.
- Any other policy is a platform rule. Change the object.

Other host webhooks, such as the ingress-nginx and External Secrets validators, report a rejection
the same way, with their own name after `admission webhook`. A message that says
`failed calling webhook` instead of `denied the request` means the host could not reach the webhook;
the object itself may be fine, and the syncer tries again.

The syncer retries a rejected object on its own, and waits longer after each attempt. The host
rejects every retry until the object or the rule changes, so waiting does not help: fix the object
and apply it again. Pods and PersistentVolumeClaims accept few changes in place: delete and
re-create them, or fix the Deployment or StatefulSet that makes them. After the platform team
changes your allowlist, change the object so the syncer tries again at once, for example:

```bash
kubectl annotate pvc my-app-data -n my-namespace sync-retry="$(date +%s)" --overwrite
```

Kyverno also records its results in policy reports on the host, which you cannot read. Ask the
platform team (s3df-help) if a message is unclear, and send them the whole message: it names your
host namespace, the object and the policy.

## Examples

| File | What it shows |
|---|---|
| [`deployment.yaml`](deployment.yaml) | A Deployment whose pods pass the host's pod rules: an `emptyDir` for scratch space instead of `hostPath`, no privileged container, requests and limits |
| [`service-nodeport-rejected.yaml`](service-nodeport-rejected.yaml) | A NodePort Service, which the host rejects. Apply it to see a `SyncError`, then delete it |

The manifests set no namespace: apply them with `-n` to a namespace of your own.

```bash
kubectl apply -n my-namespace -f deployment.yaml -f service-nodeport-rejected.yaml
kubectl get pods -n my-namespace -l app=my-app      # Running: the host accepted the pods

kubectl describe service my-app-nodeport -n my-namespace
# Warning  SyncError  ... enforce-k-disallow-services-nodeport-type-k-all:
#   validate-nodeport: 'validation error: Services of type NodePort are not allowed. ...'

kubectl delete -n my-namespace -f service-nodeport-rejected.yaml -f deployment.yaml
```

## Mistakes that leave an object stuck or changed

| Mistake | Result |
|---|---|
| Taking a successful `kubectl apply` as proof that the object works | The host checks the copy afterwards. Check that pods run, and look for `SyncError` events |
| Waiting for a rejected object to start | It never does: the host rejects every retry. Change the object, or ask for an allowlist change |
| Copying Ingress hostnames or StorageClasses from another vcluster's manifests | They are approved per vcluster, so the host rejects the copy unless they are approved for yours too. Use the ones approved for yours |
| One Ingress for two hostnames, even when both are approved | Rejected. Write one Ingress per hostname |
| An HTTPRoute without `hostnames`, or with a hostname that is not on your allowlist | Never published. Always set `hostnames`; an unapproved hostname gives no error |
| Setting `ingressClassName`, or an `ipStrategy` on an `ipAllowList` Middleware | Replaced on the host copy |
| A `hostPath` volume to reach S3DF data | Rejected. Use a claim in an S3DF filesystem class: see [S3DF filesystems](../storage/sdf-filesystem/README.md) |
| Objects in the `default` namespace | Against platform policy. Create a namespace and pass `-n` |
| Editing a rejected pod or claim in place | Most of their fields cannot change. Delete and re-create them, or fix the controller that makes them |
| Reading a finished Job's pods hours later | The host has deleted them, within 15 minutes of a pod being both finished and 10 minutes old. Save what you need while the pod exists |

The Kyverno [documentation](https://kyverno.io/docs/) explains policies, rules and policy reports.
