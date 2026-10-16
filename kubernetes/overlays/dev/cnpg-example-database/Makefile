# Reads the database owner's username and password from one Vault secret into etc/.secrets/,
# applies this directory with kustomize, then deletes the files. Log in first: vault login -method=ldap
VAULT_ADDR ?= https://vault.slac.stanford.edu
export VAULT_ADDR

# Your own Vault path, including the secret/ mount. The keys become the files kustomization.yaml
# lists, and the username must equal bootstrap.initdb.owner in cnpg-example-database.yaml ("app").
SECRET_PATH ?= secret/my-facility/my-vcluster/cnpg-example/exampledb
SECRET_KEYS ?= username password

# A namespace of your own in your vcluster. Platform policy forbids the default namespace.
NAMESPACE ?= my-namespace

.PHONY: check secrets dump apply clear-secrets

check:
	@vault token lookup > /dev/null 2>&1 || { echo "Not logged in to Vault at $(VAULT_ADDR). Run: vault login -method=ldap"; exit 1; }

secrets: check
	@umask 077; mkdir -p etc/.secrets; \
	for key in $(SECRET_KEYS); do \
	  vault kv get -field="$$key" "$(SECRET_PATH)" > "etc/.secrets/$$key" || { rm -rf etc/.secrets; exit 1; }; \
	done

# Renders the manifests, including the Secret, to stdout. Don't redirect it into a file in git.
dump: secrets
	@kubectl kustomize .; status=$$?; rm -rf etc/.secrets; exit $$status

apply: secrets
	@kubectl apply -k . -n "$(NAMESPACE)"; status=$$?; rm -rf etc/.secrets; exit $$status

clear-secrets:
	@rm -rf etc/.secrets
