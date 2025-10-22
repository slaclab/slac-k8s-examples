
NAMESPACE = mariadb-system
RESOURCES_DIR = resources
CRDS_DIR = crds

mariadb-operator:
	helm repo add mariadb-operator https://mariadb-operator.github.io/mariadb-operator
	# needs kubectl slice plugging
	helm template mariadb-operator-crds mariadb-operator/mariadb-operator-crds | kubectl slice -t "{{.kind | lower}}-{{.metadata.name | lower}}.yaml" -o $(CRDS_DIR)/
	helm template mariadb-operator mariadb-operator/mariadb-operator --create-namespace -n $(NAMESPACE) --version 0.38.1 | kubectl slice -t "{{.kind | lower}}-{{.metadata.name | lower}}.yaml" -o $(RESOURCES_DIR)/

apply-crds:
	kubectl apply -f $(CRDS_DIR)/

create-namespace:
	kubectl create namespace $(NAMESPACE)

apply-non-namespaced:
	kubectl apply -f $(RESOURCES_DIR)/clusterrole-mariadb-operator-mmontes.yaml
	kubectl apply -f $(RESOURCES_DIR)/clusterrole-mariadb-operator-mmontes-cert-controller.yaml
	kubectl apply -f $(RESOURCES_DIR)/clusterrole-mariadb-operator-mmontes-edit.yaml
	kubectl apply -f $(RESOURCES_DIR)/clusterrole-mariadb-operator-mmontes-view.yaml
	kubectl apply -f $(RESOURCES_DIR)/clusterrolebinding-mariadb-operator-mmontes.yaml
	kubectl apply -f $(RESOURCES_DIR)/clusterrolebinding-mariadb-operator-mmontes-cert-controller.yaml
	kubectl apply -f $(RESOURCES_DIR)/clusterrolebinding-mariadb-operator-mmontes:auth-delegator.yaml
	kubectl apply -f $(RESOURCES_DIR)/mutatingwebhookconfiguration-mariadb-operator-mmontes-webhook.yaml
	kubectl apply -f $(RESOURCES_DIR)/validatingwebhookconfiguration-mariadb-operator-mmontes-webhook.yaml

apply-resources-namespaced:
	kubectl apply -n $(NAMESPACE) -f $(RESOURCES_DIR)/role-mariadb-operator-mmontes.yaml
	kubectl apply -n $(NAMESPACE) -f $(RESOURCES_DIR)/rolebinding-mariadb-operator-mmontes.yaml
	kubectl apply -n $(NAMESPACE) -f $(RESOURCES_DIR)/role-mariadb-operator-mmontes-cert-controller.yaml
	kubectl apply -n $(NAMESPACE) -f $(RESOURCES_DIR)/rolebinding-mariadb-operator-mmontes-cert-controller.yaml
	kubectl apply -n $(NAMESPACE) -f $(RESOURCES_DIR)/serviceaccount-mariadb-operator-mmontes.yaml
	kubectl apply -n $(NAMESPACE) -f $(RESOURCES_DIR)/serviceaccount-mariadb-operator-mmontes-cert-controller-cert-controller.yaml
	kubectl apply -n $(NAMESPACE) -f $(RESOURCES_DIR)/serviceaccount-mariadb-operator-mmontes-webhook.yaml
	kubectl apply -n $(NAMESPACE) -f $(RESOURCES_DIR)/configmap-mariadb-operator-env.yaml
	kubectl apply -n $(NAMESPACE) -f $(RESOURCES_DIR)/service-mariadb-operator-mmontes-webhook.yaml
	kubectl apply -n $(NAMESPACE) -f $(RESOURCES_DIR)/deployment-mariadb-operator-mmontes-cert-controller.yaml
	kubectl apply -n $(NAMESPACE) -f $(RESOURCES_DIR)/deployment-mariadb-operator-mmontes-webhook.yaml
	kubectl apply -n $(NAMESPACE) -f $(RESOURCES_DIR)/configmap-mariadb-operator-env.yaml
	kubectl apply -n $(NAMESPACE) -f $(RESOURCES_DIR)/deployment-mariadb-operator-mmontes.yaml

apply: apply-crds create-namespace apply-non-namespaced apply-resources-namespaced
