NAMESPACE ?= mysql-operator
VAULT_SECRET_PATH ?= secret/tid/template-app/operators/mysql

get-vault-secrets:
	mkdir -p etc/.secrets
	vault kv get --field=root-password $(VAULT_SECRET_PATH) | sed -e 's/\"//g' > etc/.secrets/root-password

clean-secrets:
	rm -rf etc/.secrets

update-operator:
	curl -L "https://raw.githubusercontent.com/mysql/mysql-operator/trunk/deploy/deploy-crds.yaml" > deploy-crds.yaml
	curl -L "https://raw.githubusercontent.com/mysql/mysql-operator/trunk/deploy/deploy-operator.yaml" > deploy-operator.yaml

apply: update-operator
	kubectl apply -k .
