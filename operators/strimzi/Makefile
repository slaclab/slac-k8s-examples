
NAMESPACE ?= kafka

SINGULARITY_IMAGE ?= kafka_0.31.1-kafka-3.2.3.sif

BOOTSTRAP_SERVER ?= 172.24.5.223:9094
KAFKA_PROPERTIES ?= console.properties

# the k8s secret object container the the user creds
# ensure the acl allows access for the kafkauser
KAFKA_USER ?= kafka-user
KAFKA_TOPIC ?= my-topic 
KAFKA_GROUP ?= my-group

# k8s secret for kafka cluster
KAFKA_CLUSTER_CERT ?= kafka-cluster-cluster-ca-cert
JKS_STOREPASS ?= 123456

update-operator:
	curl -L "https://strimzi.io/install/latest?namespace=$(NAMESPACE)" > strimzi-operator.yaml

persistent-single:
	curl -L https://strimzi.io/examples/latest/kafka/kafka-persistent-single.yaml > kafka-persistent-single.yaml

jks:
	rm -f kafka.server.truststore.jks
	kubectl get secrets $(KAFKA_CLUSTER_CERT) -o jsonpath='{ .data.ca\.crt }' | base64 -d > cluster.crt
	keytool -keystore kafka.server.truststore.jks -alias CARoot -import -file cluster.crt -storepass $(JKS_STOREPASS) -noprompt
	rm cluster.crt

create-singularity:
	singularity pull -F docker://quay.io/strimzi/kafka:0.31.1-kafka-3.2.3

create-properties:
	echo "sasl.mechanism=SCRAM-SHA-512" > $(KAFKA_PROPERTIES)
	echo "security.protocol=SASL_SSL" >> $(KAFKA_PROPERTIES)
	echo "ssl.truststore.location=kafka.server.truststore.jks" >> $(KAFKA_PROPERTIES)
	echo "ssl.truststore.password=$(JKS_STOREPASS)" >> $(KAFKA_PROPERTIES)
	echo -n "sasl.jaas.config=" >> $(KAFKA_PROPERTIES)
	kubectl get secrets $(KAFKA_USER) -o jsonpath='{ .data.sasl\.jaas\.config }' | base64 -d >> $(KAFKA_PROPERTIES)
	echo "" >> $(KAFKA_PROPERTIES)
	chmod 600 $(KAFKA_PROPERTIES) 

producer: create-properties
	singularity exec $(SINGULARITY_IMAGE) /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server $(BOOTSTRAP_SERVER) --topic $(KAFKA_TOPIC) --producer.config=$(KAFKA_PROPERTIES)

receiver: create-properties
	singularity exec $(SINGULARITY_IMAGE) /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server $(BOOTSTRAP_SERVER) --topic $(KAFKA_TOPIC) --group $(KAFKA_GROUP) --consumer.config=$(KAFKA_PROPERTIES)


run-dump:
	kubectl kustomize .

dump: run-dump

run-apply:
	kubectl apply -k .

apply: run-apply


