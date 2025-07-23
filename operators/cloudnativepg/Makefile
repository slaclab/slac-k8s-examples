CNPG_VERSION_MAJOR ?= '1.25'
CNPG_VERSION_MINOR ?= '2'
CNPG_NS ?= cnpg-system
KUBECTL_DEPLOY_CONTEXT ?= 'sdf-k8s01'

ensure-context:
	if [ '$(shell kubectl config current-context)' != $(KUBECTL_DEPLOY_CONTEXT) ]; then echo "Configured deployment context inccorect; expecting $(KUBECTL_DEPLOY_CONTEXT)."; exit 1; fi

resource:
	rm -rf resources/* crd/*
	cat kustomization.yaml.tmpl > kustomization.yaml
	curl -sL https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-${CNPG_VERSION_MAJOR}/releases/cnpg-${CNPG_VERSION_MAJOR}.${CNPG_VERSION_MINOR}.yaml | kubectl slice -o resources/
	mv resources/customresourcedefinition* crd/
	rm -rf resources/-.yaml resources/namespace*
	kustomize edit add resource resources/*

dump: resource
	kubectl kustomize .

apply: ensure-context
	# CRDs too long
	kubectl apply --server-side --force-conflicts -f crd/
	kubectl apply -k .
