# Installs or upgrades a pinned CloudNativePG operator release in your vcluster.
# Needs: kubectl, kustomize, kubectl-slice (https://github.com/patrickdappollonio/kubectl-slice), curl.
#
#   make resource   downloads the release manifest and splits it into crd/ and resources/
#   make dump       renders what `make apply` would send, without touching the cluster
#   make apply      applies the CRDs (server-side) and then the operator, with the memory patch

# The release to install. Pick one from https://github.com/cloudnative-pg/cloudnative-pg/releases
# and keep the two parts separate: the branch is release-<major>, the file is cnpg-<major>.<minor>.yaml.
CNPG_VERSION_MAJOR ?= 1.27
CNPG_VERSION_MINOR ?= 1
CNPG_RELEASE_URL = https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-$(CNPG_VERSION_MAJOR)/releases/cnpg-$(CNPG_VERSION_MAJOR).$(CNPG_VERSION_MINOR).yaml

# The kubectl context of YOUR vcluster, never the host cluster. The check below refuses to apply
# anything while another context is current.
KUBECTL_DEPLOY_CONTEXT ?= my-vcluster

.PHONY: ensure-context resource dump apply

ensure-context:
	@if [ "$$(kubectl config current-context)" != "$(KUBECTL_DEPLOY_CONTEXT)" ]; then \
	  echo "Current kubectl context is not $(KUBECTL_DEPLOY_CONTEXT). Set KUBECTL_DEPLOY_CONTEXT or switch context."; exit 1; fi

# Splits the upstream release manifest into one file per object, so the operator you apply is
# reviewable and pinned. The CRDs go to crd/ (applied separately, see apply); the Namespace is
# dropped because ns.yaml provides it.
resource:
	mkdir -p resources crd
	rm -rf resources/* crd/*
	cp kustomization.yaml.tmpl kustomization.yaml
	curl -sfL "$(CNPG_RELEASE_URL)" | kubectl slice -o resources/
	mv resources/customresourcedefinition* crd/
	rm -f resources/-.yaml resources/namespace*
	kustomize edit add resource resources/*

dump: resource
	kubectl kustomize .

# The Cluster and Pooler CRDs are too large for client-side `kubectl apply` (the last-applied
# annotation would exceed the 256 KiB limit), so they go through server-side apply.
apply: ensure-context
	kubectl apply --server-side --force-conflicts -f crd/
	kubectl apply -k .
	kubectl -n cnpg-system rollout status deployment/cnpg-controller-manager
