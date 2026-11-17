# Installs or upgrades a pinned Strimzi operator release in your vcluster.
# Needs: kubectl, helm 3.8 or newer, curl.
#
#   make resource   downloads the release's CRDs and renders the operator chart with the values file
#   make dump       renders what `make apply` would send, without touching the cluster
#   make apply      applies the CRDs and the operator (server-side) and waits for the operator

# The release to install. Pick one from https://github.com/strimzi/strimzi-kafka-operator/releases
# and set defaultImageTag in strimzi-kafka-operator-values.yaml to the same version.
STRIMZI_KAFKA_OPERATOR_VERSION ?= 0.47.0
NAMESPACE ?= strimzi-kafka-operator

# The kubectl context of YOUR vcluster, never the host cluster. The check below refuses to apply
# anything while another context is current.
KUBECTL_DEPLOY_CONTEXT ?= my-vcluster

.PHONY: ensure-context resource dump apply

ensure-context:
	@if [ "$$(kubectl config current-context)" != "$(KUBECTL_DEPLOY_CONTEXT)" ]; then \
	  echo "Current kubectl context is not $(KUBECTL_DEPLOY_CONTEXT). Set KUBECTL_DEPLOY_CONTEXT or switch context."; exit 1; fi

resource:
	curl -sfL https://github.com/strimzi/strimzi-kafka-operator/releases/download/$(STRIMZI_KAFKA_OPERATOR_VERSION)/strimzi-crds-$(STRIMZI_KAFKA_OPERATOR_VERSION).yaml -o strimzi-crds.yaml
	helm template strimzi-cluster-operator oci://quay.io/strimzi-helm/strimzi-kafka-operator \
	  --version $(STRIMZI_KAFKA_OPERATOR_VERSION) --namespace $(NAMESPACE) \
	  -f strimzi-kafka-operator-values.yaml > strimzi-kafka-operator.yaml

dump:
	kubectl kustomize .

# Server-side apply: client-side apply would store each object in a last-applied annotation,
# limited to 256 KiB, and the Kafka CRD already fills most of it.
apply: ensure-context
	kubectl apply --server-side --force-conflicts -k .
	kubectl -n $(NAMESPACE) rollout status deployment/strimzi-cluster-operator
