STRIMZI_KAFKA_OPERATOR_VERSION ?= 0.47.0
NAMESPACE ?= strimzi-kafka-operator

strimzi-kafka-operator:
	curl -L https://github.com/strimzi/strimzi-kafka-operator/releases/download/$(STRIMZI_KAFKA_OPERATOR_VERSION)/strimzi-crds-$(STRIMZI_KAFKA_OPERATOR_VERSION).yaml -o strimzi-crds.yaml
	helm repo add strimzi-cluster-operator https://strimzi.io/charts/ 
	helm repo update strimzi-cluster-operator
	helm template strimzi-cluster-operator --version $(STRIMZI_KAFKA_OPERATOR_VERSION) --namespace $(NAMESPACE) -f strimzi-kafka-operator-values.yaml oci://quay.io/strimzi-helm/strimzi-kafka-operator > strimzi-kafka-operator.yaml 

run-apply:
	kubectl -n $(NAMESPACE) apply -k .

apply: run-apply	
