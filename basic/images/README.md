# Container images and pulls (Spegel)

Every pod in your vcluster runs an image that a host node pulls with containerd. On the S3DF
Kubernetes platform, the nodes pull through Spegel, a peer-to-peer mirror that runs on every node
and serves images other nodes already hold. You do not configure it, but it changes how tags
behave and what a private image protects. This guide says how to reference images so that you
know what runs, and how to pull from a private registry inside a vcluster.

## How a pull works

Write the image reference and, for a private registry, `imagePullSecrets` in your pod. The
platform does the rest:

1. The vcluster syncs the pod to the host cluster, with the pull Secret it names.
2. The kubelet on the chosen node asks containerd for the image, following the container's
   `imagePullPolicy`.
3. containerd asks Spegel first. Spegel looks for a node in the cluster that already has the
   image, for up to 20 ms, and streams the layers from that node.
4. If no node has it, containerd pulls from the upstream registry, with your credentials if the
   pod names a pull Secret. The image then becomes available to every other node through Spegel.

Nodes pull from each other, so an image is downloaded from the registry about once per cluster,
not once per node. That is what Spegel is for: faster pod starts, less traffic leaving the
cluster, and fewer pulls counted against a registry's rate limits. Spegel mirrors every registry and does not change the
image reference your pod uses. It is a cache, not a store: if no node has the image and the
upstream registry is unreachable, the pull fails as it would without a mirror.

## Tags, digests and what actually runs

Spegel resolves tags as well as layers. When a node asks for `my-app:v2`, Spegel answers with the
digest that a node in the cluster already holds for that tag, without asking the registry. This
has one consequence you must plan for: **a tag resolves to the first digest pulled under it, for
as long as any node in the cluster holds that image.** Pushing a new build under the same tag and
restarting your pods does not reliably give you the new build; it can also give you a mix of old
and new across nodes.

| Reference | Default `imagePullPolicy` | What runs |
|---|---|---|
| `my-app@sha256:<digest>` | `IfNotPresent` | Exactly that build, always. Use this when it matters that every pod runs the same code |
| `my-app:1.4.2`, a tag used for one build only | `IfNotPresent` | That build, as long as nobody pushes a different image under the same tag |
| `my-app:latest`, `my-app:main`, `my-app:dev`, or a reused tag | `Always` for `latest` or no tag, `IfNotPresent` otherwise | Whatever digest the cluster first pulled for that tag, for as long as any node holds it. Not the newest push |

Rules that follow from this:

- Give every build its own tag, or reference the digest. Never deploy `latest`, and never
  re-push a tag that is already deployed.
- `imagePullPolicy: Always` does not help with a reused tag. It makes the kubelet ask containerd
  on every start, but containerd asks Spegel, and Spegel answers with the digest already in the
  cluster. It only adds a round trip.
- To roll out a new build, change `image` in the manifest to the new tag or digest. The
  Deployment then replaces the pods, and `kubectl rollout status` tells you when it is done. A
  `kubectl rollout restart` with an unchanged `image` can restart the old build.
- `imagePullPolicy` is fixed when the object is created. Changing a Deployment's `image` from a
  version tag to `latest` later does not change its policy to `Always`.

A digest reference is `<repository>@sha256:<64 hex digits>`. Read it from the registry with
`docker buildx imagetools inspect my-registry/my-app:1.4.2`, `crane digest ...` or `skopeo inspect
...`, or from a running pod with `kubectl get pod ... -o jsonpath='{.status.containerStatuses[*].imageID}'`
(see [Checking](#checking)). For a multi-architecture image, use the digest of the index, which
is what the tag points to, not the digest of one platform's manifest.

## Private registries

A private image needs a pull Secret of type `kubernetes.io/dockerconfigjson` in the same
namespace as the pod, named in the pod's `imagePullSecrets`. Spegel supplies no credentials and
has no other mirror behind it: a pull from the registry uses the Secret your pod names.

| Field | Value | What it is for |
|---|---|---|
| `spec.imagePullSecrets[].name` | The Secret's name, for example `my-app-registry` | Credentials for every container and init container of the pod. A ServiceAccount's `imagePullSecrets` works too and saves repeating it in each pod |
| Secret `type` | `kubernetes.io/dockerconfigjson` | The registry login, as a Docker `config.json` under the key `.dockerconfigjson` |

Make the Secret from Vault, like any other Secret in your vcluster; the
[secrets overview](../secrets/README.md) compares the methods. In a vcluster with the External
Secrets switch on (see [Your vcluster](../vcluster/README.md)), an ExternalSecret with a `dockerconfigjson` template keeps the Secret in step with
the token in Vault:
[`externalsecret-image-pull-secret.yaml`](../secrets/external-secrets/externalsecret-image-pull-secret.yaml)
in the [External Secrets guide](../secrets/external-secrets/README.md). Elsewhere, read the
username and token from Vault on your workstation and create the Secret in the pod's namespace:

```bash
kubectl create secret docker-registry my-app-registry -n my-namespace \
  --docker-server=ghcr.io \
  --docker-username="$(vault kv get -field=username secret/my-facility/my-vcluster/my-app/registry)" \
  --docker-password="$(vault kv get -field=token secret/my-facility/my-vcluster/my-app/registry)"
```

Use a token with pull-only rights, never your own registry password. The Secret stays in your
vcluster until a pod names it; then the vcluster syncs it to the host namespace of your vcluster,
where the kubelet reads it. The vcluster syncs only Secrets that a pod uses, so a pull Secret no
pod references never leaves your vcluster.

### What a private image does and does not protect

Registry credentials control who can pull from the registry. They do not keep the image's
contents from other tenants inside the cluster:

- Spegel serves every image a node holds to every other node without checking registry
  credentials: a mirror never receives them, and Spegel could not check them if it did. After one
  node has pulled your private image, a pod in any vcluster that references the same image can
  start from the mirror without your Secret, for as long as a node holds the image. To containerd
  and the kubelet, a pull from a peer is an ordinary successful pull.
- The nodes that run your pods are visible in your vcluster, and the platform does not clear
  their image status: it lists images held on the node, including images other tenants pulled. Other tenants see your image names and tags the
  same way.

Treat the contents of an image as readable by every tenant on the platform. Never bake a secret,
a token or a private key into an image: pass it in at run time from a Secret (see
[Secrets](../secrets/README.md)). A private registry still protects the image outside the
cluster and lets you control who can push.

## Examples

| File | What it shows |
|---|---|
| [`deployment-pinned-tag.yaml`](deployment-pinned-tag.yaml) | An image pinned to a version tag, with `imagePullPolicy: IfNotPresent` |
| [`deployment-pinned-digest.yaml`](deployment-pinned-digest.yaml) | The same image pinned by digest |
| [`deployment-private-image.yaml`](deployment-private-image.yaml) | A pull from a private registry with `imagePullSecrets` |

The manifests set no namespace. Apply them to a namespace of your own with `-n`: platform policy
forbids the vcluster's `default` namespace, and [Your vcluster](../vcluster/README.md) shows how
to create one. The three Deployments share the name `my-app`: apply one at a time.
`deployment-private-image.yaml` needs the Secret `my-app-registry` from the section above and a
real private image in place of `ghcr.io/my-org/my-app:1.0.0`.

## Mistakes that run the wrong image or break a pull

| Mistake | Result |
|---|---|
| `latest`, a branch name or another reused tag | Pods run the digest the cluster first pulled under that tag, for as long as any node holds it. A new push under the same tag is not picked up, or only on some nodes |
| `imagePullPolicy: Always` to pick up a re-pushed tag | No effect on Spegel's answer; the old digest still runs. Change the tag or use a digest |
| A new build pushed under a tag that is already running | Any mix of old and new pods, depending on which nodes hold which digest. Build a new tag |
| `kubectl rollout restart` after a push to the same tag | Restarts the pods with the old build. Change `image` in the manifest instead |
| A pull Secret in another namespace than the pod, or a misspelt Secret name | The pod's events show `FailedToRetrieveImagePullSecret`, the pull goes out without credentials, and the pod stays in `ImagePullBackOff` with `unauthorized` or `denied`. The Secret must be in the pod's namespace, under the name the pod uses |
| A private image without `imagePullSecrets` | `ImagePullBackOff` on a node where no copy is available, but a start without credentials where the mirror has one. The pod works on some nodes and not others. Always name the Secret |
| A secret, token or key copied into the image | Readable by every tenant through the mirror and through any node that holds the image. Pass it in from a Secret at run time |
| A misspelt image name or tag | `ImagePullBackOff` with `not found` or `manifest unknown`. The kubelet retries with a delay that grows to 5 minutes, so fixing the name can take a few minutes to show |

An `ImagePullBackOff` that names your registry and `unauthorized` or `denied` means the
credentials were sent but refused: check the token's rights and expiry in the registry, and that
the Secret holds the registry hostname the image uses (`ghcr.io`, not `https://ghcr.io/v2/`).

## Checking

```bash
# The image references of a Deployment's pods, and the digest each container actually runs.
kubectl get pods -n my-namespace -l app=my-app \
  -o custom-columns='POD:.metadata.name,IMAGE:.spec.containers[*].image,RUNNING:.status.containerStatuses[*].imageID'

# Every pod should show the same RUNNING digest. Different digests under one tag mean the tag
# was reused; pin the digest or build a new tag.

# Why a pod cannot pull: read the events at the end.
kubectl describe pod my-app-xxxxx -n my-namespace

# The pull Secret exists in the pod's namespace and has the right type.
kubectl get secret my-app-registry -n my-namespace -o jsonpath='{.type}{"\n"}'
```

Upstream references: [Spegel](https://spegel.dev/docs/) (see its pages on resolving tags and
its FAQ on private images) and
[Kubernetes images](https://kubernetes.io/docs/concepts/containers/images/) for pull policy and
pull Secrets.
