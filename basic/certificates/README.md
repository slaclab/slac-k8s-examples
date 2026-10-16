# TLS certificates (cert-manager)

cert-manager issues and renews TLS certificates for traffic inside the cluster: HTTPS between your
services, mutual TLS, and the webhooks and databases that operators run. You write Issuers and
Certificates in your vcluster; the cert-manager on the host cluster signs them, and the certificate
and its key appear in your namespace as a Secret. Public HTTPS on a hostname one level below
`slac.stanford.edu`, through an HTTPRoute or an Ingress, needs no certificate from you.

cert-manager works in your vcluster only with the cert-manager switch, which the platform team sets
for each vcluster. It is on by default for a new vcluster; existing vclusters may differ. With it,
`kubectl api-resources --api-group=cert-manager.io` lists `certificates` and `issuers`. Without it,
nothing on the host issues your certificates. Ask the platform team (s3df-help) to change it; see
[Your vcluster](../vcluster/README.md#features-and-allowlists-the-platform-sets).

## When you need a certificate

| Traffic | What you do |
|---|---|
| Clients to `my-app.slac.stanford.edu`, through an [HTTPRoute](../httproutes/README.md) or an [Ingress](../ingresses/README.md) | Nothing. The SLAC F5 load balancer in front of the gateway and ingress-nginx terminates TLS with the wildcard certificate `*.slac.stanford.edu`. The Ingress needs no `tls` section and no cert-manager annotations |
| ingress-nginx to your pod over HTTPS (annotation `nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"`) | Give the pod any certificate. ingress-nginx does not verify it, so a self-signed one is enough |
| Clients to a [LoadBalancer Service](../services/README.md), including mutual TLS from outside the cluster | Your pod terminates TLS: the connection does not pass the F5. Use a private CA and give clients its `ca.crt`. For a publicly trusted certificate, ask the platform team (s3df-help) |
| Your services to each other, verified | A private CA, server certificates signed by it, and `ca.crt` in every client |
| Mutual TLS inside the cluster | As above, and a client certificate for each client |
| An operator's webhooks or database TLS | Usually nothing: the operator creates its own. See [Operators](#operators-that-create-certificates) |

The F5 holds the publicly trusted certificate, so applications behind it never hold its key or
renew it. The wildcard covers one label: `my-app.slac.stanford.edu`, not
`my-app.sdf.slac.stanford.edu`. Ask the platform team (s3df-help) about any other name. An HTTPRoute
cannot bring its own certificate: the gateway is shared by all vclusters, so its HTTPS listener and
that listener's certificate belong to the platform.

## How a certificate reaches your namespace

1. You create an Issuer and a Certificate in a namespace of your vcluster.
2. The vcluster's cert-manager plugin copies both to your host namespace `vcluster--<name>`, under
   host names, and rewrites the references between them: `secretName`, `issuerRef` when its `kind`
   is `Issuer`, and a CA Issuer's `ca.secretName`.
3. cert-manager on the host signs the certificate and writes the Secret.
4. The plugin copies the Secret into your namespace under your `secretName`, and copies the status
   of the Issuer and the Certificate back, so `kubectl get certificates` shows `READY`.
5. cert-manager renews the certificate before it expires and updates the Secret. Pods that mount the
   Secret as a volume get the new files; the application must reload them, for example on a restart.

A Secret that one of your Issuers names goes the other way: if you bring a CA of your own, create
its Secret (`tls.crt`, `tls.key`) in your namespace and set it as `ca.secretName`, and the plugin
copies the Secret to your host namespace for cert-manager to sign with.

One cert-manager on the host serves every vcluster with the switch on, so you don't run its
controller, webhook and CRDs yourself. Your vcluster has the Certificate and Issuer kinds only:
CertificateRequests and ClusterIssuers stay on the host, and the status of your Certificate is where
you see what happened.

## Issuers

| Issuer | Kind | Use it for |
|---|---|---|
| `selfsigned-cluster-issuer` | ClusterIssuer, on the host | A self-signed certificate in one step, where nothing verifies it, such as the hop from ingress-nginx to your pod. Each certificate signs itself, so there is no shared CA to give clients |
| `selfSigned: {}`, in your namespace | Issuer | Signing your own CA certificate |
| `ca.secretName: <your CA's Secret>`, in your namespace | Issuer | Signing server and client certificates with that CA |

`selfsigned-cluster-issuer` is the only ClusterIssuer. There is no ACME (Let's Encrypt) or InCommon
issuer: the F5 handles all public TLS. Certificates from these issuers are trusted only by clients
you give the CA to. Your vcluster has no ClusterIssuer kind, so `kubectl get clusterissuers` fails
there; refer to `selfsigned-cluster-issuer` by name. A ClusterIssuer you create in your vcluster
yourself is never used: the plugin copies a ClusterIssuer reference unchanged, so the host looks
for the name among its own ClusterIssuers.

Anyone who can read your CA's Secret can sign certificates that your clients accept. Keep the CA in
a namespace that only its owners use.

## Certificate settings

| Field | Value | What it is for |
|---|---|---|
| `issuerRef.kind` | `Issuer` or `ClusterIssuer`, always written out | cert-manager treats a missing kind as `Issuer`, but the plugin maps an Issuer's name to its host name only when `kind: Issuer` is set |
| `issuerRef.name` | An Issuer in the same namespace, or `selfsigned-cluster-issuer` | Chooses the signer |
| `secretName` | For example `my-app-tls` | The Secret that receives `tls.crt`, `tls.key` and `ca.crt` |
| `dnsNames` | The names clients use inside your vcluster: `my-app`, `my-app.my-namespace.svc`, `my-app.my-namespace.svc.cluster.local` | A client rejects a certificate that lacks the name it connected to |
| `usages` | `server auth` for a server, `client auth` for an mTLS client | Limits what the certificate is accepted for |
| `isCA` | `true` on the CA certificate only | Lets the certificate sign others |
| `duration`, `renewBefore` | For example `2160h` and `360h` (90 and 15 days) | Lifetime, and when cert-manager renews. Give a CA a much longer lifetime than the certificates it signs |

Each renewal creates a new private key unless `privateKey.rotationPolicy` is `Never`. Set `Never`
on your CA, as `certificate-ca.yaml` does: the renewed CA keeps its key, so the certificates it
signed earlier still verify against the new `ca.crt`. With a new CA key, clients that already hold
the new `ca.crt` reject servers whose certificates the old key signed.

## Operators that create certificates

Some operators and charts create their own Issuers and Certificates, for their webhooks or for
database TLS. These pass through the plugin like your own:

- The Percona MongoDB operator creates a CA, Issuers and the cluster's TLS certificates with
  cert-manager.
- Installing the CloudNativePG barman-cloud plugin creates an Issuer and client and server
  Certificates in `cnpg-system`. The plugin needs the cert-manager switch; see
  [CloudNativePG backups](../../operators/cloudnativepg/backups/README.md).
- Charts with a cert-manager option, such as mariadb-operator's, use it for their webhook
  certificates when you turn it on.

After installing one, check two things:

- Every `issuerRef` has a `kind`. A chart that leaves it out, such as the Slurm operator's,
  produces Certificates that are never issued, and their status does not say why. Add
  `kind: Issuer` to the rendered manifests, for example with a kustomize patch.
- Webhook configurations exist only in your vcluster, and cert-manager's CA injector runs on the
  host, so the `cert-manager.io/inject-ca-from` annotation fills nothing. A webhook whose `caBundle`
  is empty fails every call, and with `failurePolicy: Fail` it blocks the objects it covers. Use the
  operator's own certificate controller where it has one: the
  [MariaDB](../../operators/mariadb-operator/README.md) install runs mariadb-operator's
  cert-controller, which fills `caBundle` without cert-manager.

CloudNativePG creates its own CA and server certificate for each cluster, in the Secrets
`<cluster>-ca` and `<cluster>-server`, and needs no cert-manager for them; see
[PostgreSQL with CloudNativePG](../../operators/cloudnativepg/README.md). For MongoDB, see
[MongoDB with the Percona operator](../../operators/percona/README.md).

Don't install cert-manager itself in a vcluster with the switch on, also not as a dependency of
another chart: the plugin already provides the cert-manager kinds, and two controllers would act on
the same Certificates. If you need your own cert-manager, ask the platform team (s3df-help) to turn
the switch off first.

## Examples

| File | What it shows |
|---|---|
| [`issuer-selfsigned.yaml`](issuer-selfsigned.yaml) | A selfSigned Issuer that signs only the CA certificate |
| [`certificate-ca.yaml`](certificate-ca.yaml) | Your private CA (`isCA: true`), in the Secret `my-app-ca`, keeping its key on renewal |
| [`issuer-ca.yaml`](issuer-ca.yaml) | A CA Issuer that signs with `my-app-ca` |
| [`certificate-server.yaml`](certificate-server.yaml) | A server certificate for the Service `my-app` |
| [`certificate-client.yaml`](certificate-client.yaml) | A client certificate for mutual TLS |
| [`certificate-cluster-issuer.yaml`](certificate-cluster-issuer.yaml) | A self-signed certificate from `selfsigned-cluster-issuer`, for a hop nothing verifies |
| [`configmap-nginx.yaml`](configmap-nginx.yaml) | nginx configuration: HTTPS on port 8443, client certificates required |
| [`deployment.yaml`](deployment.yaml) | nginx serving with the server certificate |
| [`service.yaml`](service.yaml) | The Service `my-app`, port 443 |
| [`pod-client.yaml`](pod-client.yaml) | curl calling `https://my-app/` with the client certificate, verifying the server against `ca.crt` |

The manifests set no namespace. Apply them to a namespace of your own with `-n`: platform policy
forbids the vcluster's `default` namespace, and
[Your vcluster](../vcluster/README.md#namespaces) shows how to create one. Replace `my-namespace`
in the `dnsNames` of `certificate-server.yaml` with your namespace first.

```bash
kubectl apply -n my-namespace -f issuer-selfsigned.yaml -f certificate-ca.yaml -f issuer-ca.yaml \
  -f certificate-server.yaml -f certificate-client.yaml
kubectl wait -n my-namespace --for=condition=Ready certificate --all --timeout=2m
kubectl apply -n my-namespace -f configmap-nginx.yaml -f deployment.yaml -f service.yaml
kubectl rollout status -n my-namespace deployment/my-app
kubectl apply -n my-namespace -f pod-client.yaml
kubectl logs -n my-namespace my-app-client   # hello, CN=my-app-client

# Removes the objects. The Secrets stay, so delete them too.
kubectl delete -n my-namespace --ignore-not-found -f pod-client.yaml -f service.yaml \
  -f deployment.yaml -f configmap-nginx.yaml -f certificate-client.yaml -f certificate-server.yaml \
  -f issuer-ca.yaml -f certificate-ca.yaml -f issuer-selfsigned.yaml
kubectl delete secret -n my-namespace --ignore-not-found my-app-tls my-app-client-tls my-app-ca
```

`my-app-client` exits after one request. The platform deletes finished pods 10 to 25 minutes after
they are created, so read the log soon; see [Jobs and CronJobs](../jobs/README.md).

## Mistakes that break a certificate or expose a key

| Mistake | Result |
|---|---|
| `issuerRef` without `kind`, written by you or by a chart | The host copy refers to the Issuer's vcluster name, which doesn't exist on the host. The certificate is never issued, and the Certificate's status does not say why |
| A ClusterIssuer other than `selfsigned-cluster-issuer`, for example a Let's Encrypt issuer from another cluster's manifests, or one you created in your vcluster | The host has no ClusterIssuer of that name. The Certificate never becomes Ready |
| A `cert-manager.io/cluster-issuer` or `cert-manager.io/issuer` annotation on an Ingress with a `tls` section | The host cert-manager creates a Certificate for the Ingress's `tls` Secret, and it appears in your vcluster. With an issuer that doesn't exist, it never becomes Ready. Leave out the annotations and `tls`: the F5 serves the certificate clients see |
| Host names, such as `my-app-x-my-namespace-x-vcluster--my-vcluster`, in `dnsNames` | Clients in your vcluster connect with vcluster names, so verification fails |
| A client without the CA's `ca.crt` | Verification fails: these certificates are not publicly trusted |
| Mounting the Secret with `subPath`, or reading it into environment variables | The pod doesn't see renewals. It keeps the old certificate and fails when that expires |
| Expecting `kubectl delete certificate` to remove the key | The Secret stays: the host cert-manager does not delete a Secret with its Certificate. Delete the Secret yourself |
| Installing cert-manager in a vcluster with the switch on | Two controllers issue into the same Secrets, and the Certificates fail with `IncorrectCertificate`. Ask the platform team to turn the switch off first |
| Relying on `cert-manager.io/inject-ca-from` for a webhook | `caBundle` stays empty and every call to the webhook fails |

## Checking

```bash
# With the switch on, the list includes certificates and issuers.
kubectl api-resources --api-group=cert-manager.io

# READY True. A READY that stays empty: the object has no copy on the host. Check the switch, and
# compare the object with the examples.
kubectl get issuers,certificates -n my-namespace
kubectl describe certificate my-app-tls -n my-namespace   # the conditions explain a READY False

# The Secret, and what its certificate says.
kubectl get secret my-app-tls -n my-namespace             # type kubernetes.io/tls
kubectl get secret my-app-tls -n my-namespace -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -subject -issuer -enddate

# A webhook's caBundle: 0 means empty.
kubectl get validatingwebhookconfiguration <name> \
  -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | wc -c
```

If a Certificate stays not Ready and its conditions don't say why, ask the platform team
(s3df-help): cert-manager's logs and the CertificateRequests are on the host.

cert-manager reference: [Certificate](https://cert-manager.io/docs/usage/certificate/),
[SelfSigned issuer](https://cert-manager.io/docs/configuration/selfsigned/),
[CA issuer](https://cert-manager.io/docs/configuration/ca/).
