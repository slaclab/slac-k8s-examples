SECRET_PATH=secret/tid/template-app
CNPG_VERSION ?= 1.18
PERCONA_MONGODB_VERSION ?= v1.13.0
PERCONA_MONGODB_NAMESPACE=percona-mongodb

get-vault-secrets:
	mkdir -p etc/.secrets
	vault kv get --field=example-secret -format=json $(SECRET_PATH)/ | sed -e 's/\"//g' > etc/.secrets/example-secret
	
clean-secrets:
	rm -rf etc/.secrets/

cnpg-operator:
	curl -L https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-$(CNPG_VERSION)/releases/cnpg-$(CNPG_VERSION).0.yaml > operators/cloudnativepg/cnpg-operator.yaml
	kubectl apply -f operators/cloudnativepg/cnpg-operator.yaml

percona-mongodb-operator:
	curl -L https://raw.githubusercontent.com/percona/percona-server-mongodb-operator/$(PERCONA_MONGODB_VERSION)/deploy/bundle.yaml > operators/percona/mongodb/bundle.yaml
	curl -L https://raw.githubusercontent.com/percona/percona-server-mongodb-operator/$(PERCONA_MONGODB_VERSION)/deploy/cr-minimal.yaml > operators/percona/mongodb/cr-minimal.yaml
	kubectl create -f operators/percona/mongodb/ns.yaml
	kubectl -n $(PERCONA_MONGODB_NAMESPACE) apply -f operators/percona/mongodb

mysql-operator:
	curl -L "https://raw.githubusercontent.com/mysql/mysql-operator/trunk/deploy/deploy-crds.yaml" > operators/mysql/deploy-crds.yaml
	curl -L "https://raw.githubusercontent.com/mysql/mysql-operator/trunk/deploy/deploy-operator.yaml" > operators/mysql/deploy-operator.yaml

dump:
	kubectl kustomize . | yh

apply: 
	kubectl apply -k .

diff:
	kubectl diff -k .
