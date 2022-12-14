SECRET_PATH=secret/rubin/rubintv-broadcaster-cleanroom/
RELEASE_NAME ?= usdf-rubintv

get-secrets:
	mkdir -p etc/.secrets
#	vault kv get --field=example-secret -format=json $(SECRET_PATH)/ | sed -e 's/\"//g' > etc/.secrets/example-secret

clean-secrets:
	rm -rf etc/.secrets


helm:
	helm repo add argocd https://argoproj.github.io/argo-helm
	#helm repo add lsst-ts https://raw.githubusercontent.com/lsst-ts/argocd-csc/main/services/rubintv-broadcaster/Chart.yaml

update:
#	curl https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml > argocd-install.yaml

generate:
	helm template $(RELEASE_NAME) argocd/argo-cd --values values.yaml > argocd-install.yaml

run-dump: 
	kubectl kustomize .

dump: get-secrets generate run-dump clean-secrets

run-apply:  
	kubectl apply -k .

apply: get-secrets generate run-apply clean-secrets

run-destroy:
	kubectl delete -k .

destroy: get-secrets generate run-destroy clean-secrets

