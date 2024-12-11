KUBECTL_DEPLOY_CONTEXT ?= 'mariadb-dev'
NAMESPACE ?= dev
VERSION ?= '0.30.0'
CRD_VERSION ?= 'v0.0.30'

helm:
	helm repo add mariadb-operator https://mariadb-operator.github.io/mariadb-operator
	helm repo update
	helm template mariadb-operator --create-namespace -n $(NAMESPACE) --version $(VERSION) mariadb-operator/mariadb-operator -f mariadb-operator-values.yaml | kubectl slice -t "{{.kind | lower}}-{{.metadata.name | lower}}.yaml" -o resources/

resource: helm
	kustomize edit add resource resources/*

run-apply:
	kubectl apply -k .

crds:
	# CRD is too long
	kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/mariadb-operator/mariadb-operator/$(CRD_VERSION)/deploy/crds/crds.yaml


clean-crds: ensure-context
	kubectl delete mutatingwebhookconfiguration mariadb-operator-webhook 
	kubectl delete validatingwebhookconfiguration mariadb-operator-webhook
	kubectl delete clusterrolebinding mariadb-operator:auth-delegator
	kubectl delete clusterrolebinding mariadb-operator
	kubectl delete clusterrole mariadb-operator
	kubectl -n $(NAMESPACE) delete crd --all
	kubectl delete -R namespace $(NAMESPACE)

delete:
	kubectl delete -k .
	kubectl delete -f https://raw.githubusercontent.com/mariadb-operator/mariadb-operator/$(CRD_VERSION)/deploy/crds/crds.yaml

apply: resource crds run-apply
