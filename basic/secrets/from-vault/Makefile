SECRET_PATH ?= secret/path/to/myvaultsecret

secrets:
	mkdir -p etc/.secrets/
	for i in SECRET1 SECRET2; do vault kv get -format=table  --field=$$i $(SECRET_PATH) > api/etc/.secrets/$$i; done

clear-secrets:
	rm -rf etc/.secrets/
