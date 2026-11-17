# Reads the passwords and the S3 key from Vault into etc/.secrets/, applies this directory with
# kustomize, then deletes the files. Log in to Vault first: vault login -method=ldap
VAULT_ADDR ?= https://vault.slac.stanford.edu
export VAULT_ADDR

# Vault paths, including the secret/ mount. Each key becomes a file in etc/.secrets/.
SECRET_PATH ?= secret/my-facility/my-vcluster/my-app/mariadb
SECRET_KEYS = root_password user_password monitoring_password
S3_SECRET_PATH ?= secret/my-facility/my-vcluster/my-app/s3
S3_SECRET_KEYS = access_key secret_key
# Your vcluster's kubectl context, and a namespace of your own in it.
KUBECTL_DEPLOY_CONTEXT ?= my-vcluster
NAMESPACE ?= my-namespace

.PHONY: check secrets apply clear-secrets

check:
	@if [ "$$(kubectl config current-context)" != "$(KUBECTL_DEPLOY_CONTEXT)" ]; then echo "Current kubectl context is not $(KUBECTL_DEPLOY_CONTEXT)."; exit 1; fi
	@if [ "$(NAMESPACE)" = default ]; then echo "NAMESPACE=default: use a namespace of your own"; exit 1; fi
	@vault token lookup > /dev/null 2>&1 || { echo "Not logged in to Vault at $(VAULT_ADDR). Run: vault login -method=ldap"; exit 1; }

secrets: check
	@umask 077; mkdir -p etc/.secrets; \
	for key in $(SECRET_KEYS); do \
	  vault kv get -field="$$key" "$(SECRET_PATH)" > "etc/.secrets/$$key" || { rm -rf etc/.secrets; exit 1; }; \
	done; \
	for key in $(S3_SECRET_KEYS); do \
	  vault kv get -field="$$key" "$(S3_SECRET_PATH)" > "etc/.secrets/$$key" || { rm -rf etc/.secrets; exit 1; }; \
	done

apply: secrets
	@kubectl apply -k . -n "$(NAMESPACE)"; status=$$?; rm -rf etc/.secrets; exit $$status

clear-secrets:
	@rm -rf etc/.secrets
