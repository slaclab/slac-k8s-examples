VAULT_SECRET_PATH ?= secret/tid/app-template

get-vault-secrets:
	mkdir -p etc/.secrets
	vault kv get --field=example-secret $(VAULT_SECRET_PATH) | sed -e 's/\"//g' > etc/.secrets/example-secret

apply:
	kubectl apply -k .
