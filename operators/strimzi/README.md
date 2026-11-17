# Kafka in your vcluster (Strimzi)

Strimzi is a Kubernetes operator that runs Apache Kafka from a `Kafka` object and one or more
`KafkaNodePool` objects: it creates the Kafka pods, their volumes, the Services, the cluster
certificates, and the topic and user operators that manage `KafkaTopic` and `KafkaUser` objects.
You install the operator in your own vcluster, then describe each Kafka cluster with these
objects. See [Operators and databases](../README.md) for the model every operator guide follows.

Four per-vcluster settings matter here. The default StorageClass `wekafs--sdf-k8s01` is on every
vcluster's allowlist by default and is the right one for Kafka. Clients outside your vcluster reach
Kafka through LoadBalancer Services on a MetalLB pool your vcluster may use: `sdf-services` is open
to every vcluster, the facility ingest pools only to approved ones. Metrics reach the platform
Prometheus only with the Prometheus monitors switch. The NetworkPolicies Strimzi writes take effect
only with network isolation, which is on by default. The platform team (s3df-help) keeps these
settings. See
[Your vcluster](../../basic/vcluster/README.md#features-and-allowlists-the-platform-sets).

## How Kafka runs on the platform

1. You apply the Strimzi CRDs and the operator, one Deployment in `strimzi-kafka-operator`, in
   your vcluster. The operator watches every namespace of your vcluster. The `Kafka`,
   `KafkaNodePool`, `KafkaTopic` and `KafkaUser` objects stay in your vcluster.
2. You create a `KafkaNodePool` and a `Kafka` in a namespace of your own. The operator creates one
   pod and one PersistentVolumeClaim per node of the pool, ClusterIP Services for the internal
   listeners, LoadBalancer Services for a `loadbalancer` listener, and Secrets with the cluster CA
   and the user certificates.
3. The vcluster syncs the pods, the claims, the Services and the Secrets and ConfigMaps the pods
   use to your host namespace, `vcluster--<name>`. The Weka CSI driver provisions each claim, the
   host scheduler places the pods, and MetalLB gives each LoadBalancer Service an address.
4. Strimzi also creates PodDisruptionBudgets and NetworkPolicies for the Kafka pods. The
   PodDisruptionBudgets never reach the host, so a host node drain does not wait for your brokers;
   see [Disruptions](../../basic/scheduling/disruptions/README.md). The NetworkPolicies reach the
   host only with network isolation; see
   [Network isolation](../../basic/networking/network-policies/README.md).

Strimzi 0.46 and later run Kafka only in KRaft mode: there is no ZooKeeper. The nodes of a pool
with the `controller` role keep the cluster metadata, and the example runs three nodes that are
both controller and broker.

## Installing the operator

The files in this directory install the operator from the Strimzi Helm chart, rendered into
checked-in manifests so you can read every object before you apply it:

| File | What it does |
|---|---|
| [`Makefile`](Makefile) | `make resource` downloads the release's CRDs and renders the chart; `make dump` renders the kustomization; `make apply` applies it |
| [`strimzi-kafka-operator-values.yaml`](strimzi-kafka-operator-values.yaml) | Chart values: one operator replica watching all namespaces, image tag `0.47.0`, requests and limits |
| [`strimzi-crds.yaml`](strimzi-crds.yaml) | The CRDs of release 0.47.0 |
| [`strimzi-kafka-operator.yaml`](strimzi-kafka-operator.yaml) | The rendered operator: ServiceAccount, RBAC, ConfigMap and Deployment |
| [`kustomization.yaml`](kustomization.yaml) | Puts everything in the namespace `strimzi-kafka-operator` |
| [`ns.yaml`](ns.yaml) | The `strimzi-kafka-operator` namespace |

`make apply` needs `kubectl`; `make resource` also needs `curl` and Helm 3.8 or newer.

```bash
# Point kubectl at your vcluster, then install. KUBECTL_DEPLOY_CONTEXT must name that context:
# the Makefile refuses to apply while another context is current.
make apply KUBECTL_DEPLOY_CONTEXT=my-vcluster

kubectl get deployment strimzi-cluster-operator -n strimzi-kafka-operator
kubectl get crd | grep strimzi.io
```

`make apply` uses server-side apply. Client-side `kubectl apply` stores a copy of each object in an
annotation limited to 256 KiB, and the `Kafka` CRD already fills most of it.

## Versions and upgrades

The operator release fixes the images. Release 0.47.0 runs `quay.io/strimzi/operator:0.47.0` and
the Kafka images `quay.io/strimzi/kafka:0.47.0-kafka-<version>`, and supports Kafka 3.9.0, 3.9.1
and 4.0.0. `spec.kafka.version` must be one of these; the operator does not run any other.

To upgrade, set `STRIMZI_KAFKA_OPERATOR_VERSION` in the Makefile and `defaultImageTag` in the
values file to the new release, run `make resource`, review the diff of the rendered files, then
`make apply`. CRDs and
operator come from the same release. The operator then restarts the Kafka pods one at a time onto
the new release's images. If the new release does not support your current Kafka version, raise
`spec.kafka.version` in the same step. Upgrade Kafka itself in two steps: raise
`spec.kafka.version`, and once every pod runs it, raise `metadataVersion`. Read the upstream
[upgrade procedure](https://strimzi.io/docs/operators/0.47.0/deploying#assembly-upgrade-str)
first.

## Storage

Each volume in `spec.storage` of a `KafkaNodePool` names its class in `class`. Use
`wekafs--sdf-k8s01`, the default class: it is on every vcluster's allowlist, each claim gets its own
volume with a hard quota, and the volume mounts on any node with the Weka client, so a Kafka pod
can restart on another node. The size is the quota, and a broker whose volume is full stops. Size
it for the retention of every topic on the broker, and grow it before it fills: raise `size` in
the pool and apply it. The class allows expansion; see
[Growing a claim](../../basic/storage/weka/README.md#growing-a-claim). For other classes, see
[Choosing a StorageClass](../../basic/storage/README.md).

Kafka keeps its data safe by replicating partitions across brokers, not by backups: the platform's
backups do not include volume data, and Strimzi has no backup object. Give topics a replication
factor of 3 and `min.insync.replicas` of 2, as the example does, so the cluster keeps accepting
writes while one broker is down.

## Clients outside your vcluster

Inside your vcluster, clients connect to `my-kafka-kafka-bootstrap.my-namespace:9092`, or `:9093`
with TLS. That name does not resolve outside your vcluster. Outside clients need a listener of type
`loadbalancer`, as in [`kafka-external.yaml`](demo/kafka-external.yaml). A Kafka client first asks
the bootstrap address for the cluster's brokers, then connects to each broker directly, so the
listener creates one LoadBalancer Service per broker plus one for bootstrap, and each takes an
address from the pool. Three brokers take four addresses.

Every one of these Services must pass the host's checks for LoadBalancer Services; see
[LoadBalancer Services](../../basic/services/README.md):

| Setting in the `Kafka` | Value | Why |
|---|---|---|
| Listener `type` | `loadbalancer` | The host refuses `nodeport`: a node port takes traffic from any source on every node, and a NetworkPolicy cannot control it |
| `configuration.allocateLoadBalancerNodePorts` on the listener | `false` | Required by the host: Kubernetes defaults it to `true`, which opens a node port on every node |
| Annotation `metallb.io/address-pool` in `spec.kafka.template.externalBootstrapService` and `spec.kafka.template.perPodService` | `sdf-services`, or a pool the platform team approved for you | Required by the host: every pool hands out addresses automatically, so without it the address could come from any pool. The template covers brokers you add later |
| `configuration.loadBalancerSourceRanges` on the listener | `134.79.0.0/16`, `172.16.0.0/12` | Only clients on SLAC networks reach the addresses from outside the cluster. Traffic from inside the cluster is not checked |
| `tls: true` and `authentication.type: tls` | | Clients verify the brokers with the cluster CA and log in with a `KafkaUser` certificate |

Strimzi waits for the addresses, adds them to the broker certificates and advertises them to
clients. The bootstrap address appears in the `Kafka` status. A client needs `ca.crt` from the
Secret `my-kafka-cluster-ca-cert`, and the certificate in the Secret of its `KafkaUser`: `user.p12`
with `user.password`, or `user.crt` and `user.key`.

An address belongs to its Service, and deleting the `Kafka` deletes the Services and releases the
addresses. To keep the same addresses, ask the platform team (s3df-help) for free ones and set
`metallb.io/loadBalancerIPs` in `configuration.bootstrap.annotations` and in
`configuration.brokers[].annotations` for each broker ID. Don't use the listener's `loadBalancerIP`
fields: they set the deprecated `spec.loadBalancerIP`; see
[Fixed addresses](../../basic/services/README.md#fixed-addresses).

## Monitoring

The `metricsConfig` in the example makes each Kafka and Cruise Control pod expose JMX metrics on
the container port `tcp-prometheus` (9404). Strimzi creates no monitor for them: write a
`PodMonitor`, as in [`podmonitor-kafka.yaml`](demo/podmonitor-kafka.yaml). With the Prometheus
monitors switch, the platform syncs it to the host and limits it to your own pods; see
[ServiceMonitor and PodMonitor](../../basic/serviceMonitor/README.md).

## Examples

| File | What it shows |
|---|---|
| [`demo/kafka-nodepool.yaml`](demo/kafka-nodepool.yaml) | Three dual-role (controller and broker) nodes on 100Gi Weka volumes, with requests, limits, heap size and a spread over nodes |
| [`demo/kafka.yaml`](demo/kafka.yaml) | `my-kafka`, Kafka 4.0.0 with internal listeners only, the topic and user operators, Cruise Control and metrics |
| [`demo/kafka-external.yaml`](demo/kafka-external.yaml) | The same `my-kafka` plus a TLS `loadbalancer` listener on `sdf-services` for clients outside your vcluster |
| [`demo/configmap-kafka-metrics.yaml`](demo/configmap-kafka-metrics.yaml) | The JMX exporter rules for the Kafka pods |
| [`demo/configmap-cruise-control-metrics.yaml`](demo/configmap-cruise-control-metrics.yaml) | The JMX exporter rules for Cruise Control |
| [`demo/kafkatopic.yaml`](demo/kafkatopic.yaml) | A topic with three partitions, three replicas and a retention limit |
| [`demo/kafkauser.yaml`](demo/kafkauser.yaml) | A client identity with a TLS certificate, for the external listener |
| [`demo/podmonitor-kafka.yaml`](demo/podmonitor-kafka.yaml) | Scraping the Kafka and Cruise Control pods with the platform Prometheus |

`kafka.yaml` and `kafka-external.yaml` define the same object: apply one of them. The manifests set
no namespace. Apply them to a namespace of your own with `-n`: platform policy forbids the
vcluster's `default` namespace, and [Your vcluster](../../basic/vcluster/README.md) shows how to
create one.

```bash
cd demo
kubectl apply -n my-namespace -f configmap-kafka-metrics.yaml \
  -f configmap-cruise-control-metrics.yaml -f kafka-nodepool.yaml -f kafka.yaml
kubectl wait kafka/my-kafka -n my-namespace --for=condition=Ready --timeout=15m

kubectl apply -n my-namespace -f kafkatopic.yaml -f podmonitor-kafka.yaml

# For clients outside your vcluster: switch to the external listener and add a user.
kubectl apply -n my-namespace -f kafka-external.yaml -f kafkauser.yaml
```

## Mistakes that break or lose a Kafka cluster

| Mistake | Result |
|---|---|
| A listener of type `nodeport` | The host refuses its Services, so the listener never works. Use `loadbalancer` |
| A `loadbalancer` listener without `allocateLoadBalancerNodePorts: false` | The host refuses every Service of the listener, which never gets an address, and the `Kafka` does not become `Ready` |
| The pool annotation only on the bootstrap Service, for example in `configuration.bootstrap.annotations` | The host refuses the broker Services, which never get an address: the `Kafka` does not become `Ready`, and clients cannot reach the brokers. Use `template.perPodService` as well |
| A `KafkaTopic` or `KafkaUser` in another namespace than its `Kafka` | The topic and user operators watch only the namespace of the `Kafka`, so nothing creates the topic or the user's Secret |
| An ingest pool your vcluster is not approved for | Against platform policy: your service lands on another facility's network. Use `sdf-services`, or ask the platform team |
| Forgetting that each broker takes an address | Adding brokers to a pool takes one more pool address each |
| A class not on your allowlist | The host refuses the claims and the Kafka pods stay `Pending` |
| `deleteClaim: true` | Deleting the `Kafka` or the pool deletes the claims, and Weka deletes the data with them |
| A topic with `replicas: 1` | The topic is unavailable while its broker is down, for example during a host node drain, and lost with its volume |
| A `spec.kafka.version` the operator release does not support | The operator does not reconcile the cluster and reports the error in the `Kafka` status |
| Deleting the Strimzi CRDs, for example to uninstall | Every `Kafka`, `KafkaNodePool`, `KafkaTopic` and `KafkaUser` object is deleted |
| A second Strimzi operator in your vcluster, for example from an application chart | Both watch every namespace and act on the same objects. Keep one |
| Objects in the `default` namespace | Against platform policy. Create a namespace and pass `-n` |

## Checking

```bash
# The operator and the cluster: READY becomes True once every pod runs.
kubectl get deployment strimzi-cluster-operator -n strimzi-kafka-operator
kubectl get kafka,kafkanodepool -n my-namespace
kubectl describe kafka my-kafka -n my-namespace       # the conditions explain a cluster that is not Ready

# The pods, their claims and their Services.
kubectl get pods,pvc,svc -n my-namespace -l strimzi.io/cluster=my-kafka

# The bootstrap address of each listener, including the external one.
kubectl get kafka my-kafka -n my-namespace -o jsonpath='{range .status.listeners[*]}{.name}{"\t"}{.bootstrapServers}{"\n"}{end}'

# A LoadBalancer Service without an address: SyncError if the host refused it.
kubectl get events -n my-namespace --field-selector reason=SyncError

# Topics and users, and whether the operators have applied them.
kubectl get kafkatopic,kafkauser -n my-namespace

# The operator's own log.
kubectl logs deployment/strimzi-cluster-operator -n strimzi-kafka-operator | tail -50
```

Upstream documentation: [Strimzi 0.47.0](https://strimzi.io/docs/operators/0.47.0/overview).
