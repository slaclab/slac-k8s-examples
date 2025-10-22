KUBECTL_DEPLOY_CONTEXT ?= 'context_name'

SECRET_PATH ?= vault_secret_path
S3_SECRET_PATH ?= vault_s3_secret_path

ensure-context:
	if [ '$(shell kubectl config current-context)' != $(KUBECTL_DEPLOY_CONTEXT) ]; then echo "Configured deployment context inccorect; expecting $(KUBECTL_DEPLOY_CONTEXT)."; exit 1; fi

secrets:
	mkdir -p etc/.secrets/
	set -e; for i in root_password user_password monitoring_password other_password; do vault kv get --field=$$i $(SECRET_PATH) > etc/.secrets/$$i ; done
	set -e; for i in access_key secret_key; do vault kv get --field=$$i $(S3_SECRET_PATH) > etc/.secrets/$$i ; done

clear-secrets:
	rm -rf etc/.secrets/

dump:
	kubectl kustomize .

run-apply:
	kubectl apply -k .

apply: ensure-context secrets run-apply clear-secrets
