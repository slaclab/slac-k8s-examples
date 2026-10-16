SECRET_PATH=secret/tid/template-app

get-vault-secrets:
	mkdir -p etc/.secrets
	vault kv get --field=example-secret -format=json $(SECRET_PATH)/ | sed -e 's/\"//g' > etc/.secrets/example-secret
	
clean-secrets:
	rm -rf etc/.secrets/

# Installs the pinned CloudNativePG release into your vcluster; see operators/cloudnativepg/README.md.
# Pass KUBECTL_DEPLOY_CONTEXT=<your vcluster context>: the target refuses to run against any other context.
cnpg-operator:
	$(MAKE) -C operators/cloudnativepg resource apply

# Installs the pinned Percona Operator for MongoDB and a database into one namespace of your vcluster;
# see operators/percona/README.md. Pass NAMESPACE=<namespace> and KUBECTL_DEPLOY_CONTEXT=<your vcluster context>.
percona-mongodb-operator:
	$(MAKE) -C operators/percona/mongodb apply

mysql-operator:
	curl -L "https://raw.githubusercontent.com/mysql/mysql-operator/trunk/deploy/deploy-crds.yaml" > operators/mysql/deploy-crds.yaml
	curl -L "https://raw.githubusercontent.com/mysql/mysql-operator/trunk/deploy/deploy-operator.yaml" > operators/mysql/deploy-operator.yaml

dump:
	kubectl kustomize . | yh

apply: 
	kubectl apply -k .

diff:
	kubectl diff -k .
