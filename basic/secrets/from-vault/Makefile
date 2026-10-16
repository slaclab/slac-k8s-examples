# Reads the keys of one Vault secret into etc/.secrets/, applies this directory with kustomize,
# then deletes the files. Log in to Vault first: vault login -method=ldap
VAULT_ADDR ?= https://vault.slac.stanford.edu
export VAULT_ADDR

# The Vault path, including the secret/ mount, and the keys to read from it. Each key becomes a
# file in etc/.secrets/: list the same files in kustomization.yaml.
SECRET_PATH ?= secret/my-facility/my-vcluster/my-app/db
SECRET_KEYS ?= username password
# A namespace of your own in your vcluster. Platform policy forbids default.
NAMESPACE ?= my-namespace

.PHONY: check secrets apply clear-secrets

check:
	@vault token lookup > /dev/null 2>&1 || { echo "Not logged in to Vault at $(VAULT_ADDR). Run: vault login -method=ldap"; exit 1; }
	@if [ "$(NAMESPACE)" = default ]; then echo "NAMESPACE=default: use a namespace of your own"; exit 1; fi

secrets: check
	@umask 077; mkdir -p etc/.secrets; \
	for key in $(SECRET_KEYS); do \
	  vault kv get -field="$$key" "$(SECRET_PATH)" > "etc/.secrets/$$key" || { rm -rf etc/.secrets; exit 1; }; \
	done

apply: secrets
	@kubectl apply -k . -n "$(NAMESPACE)"; status=$$?; rm -rf etc/.secrets; exit $$status

clear-secrets:
	@rm -rf etc/.secrets
