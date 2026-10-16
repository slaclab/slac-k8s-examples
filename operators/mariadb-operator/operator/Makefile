# Installs mariadb-operator in your vcluster from a pinned release.
# Needs helm and the kubectl slice plugin (https://github.com/patrickdappollonio/kubectl-slice).

VERSION ?= 0.38.1
NAMESPACE = mariadb-system
RELEASE = mariadb-operator
KUBECTL_DEPLOY_CONTEXT ?= my-vcluster
CRDS_DIR = crds
RESOURCES_DIR = resources

# Renders the CRDs and the operator of release $(VERSION) into crds/ and resources/.
render:
	helm repo add mariadb-operator https://mariadb-operator.github.io/mariadb-operator --force-update
	helm repo update mariadb-operator
	rm -rf $(CRDS_DIR) $(RESOURCES_DIR)
	helm template mariadb-operator-crds mariadb-operator/mariadb-operator-crds --version $(VERSION) \
	  | kubectl slice -t "{{.kind | lower}}-{{.metadata.name | lower}}.yaml" -o $(CRDS_DIR)/
	helm template $(RELEASE) mariadb-operator/mariadb-operator --version $(VERSION) -n $(NAMESPACE) \
	  -f mariadb-operator-values.yaml \
	  | kubectl slice -t "{{.kind | lower}}-{{.metadata.name | lower}}.yaml" -o $(RESOURCES_DIR)/

ensure-context:
	@if [ "$$(kubectl config current-context)" != "$(KUBECTL_DEPLOY_CONTEXT)" ]; then \
	  echo "Current kubectl context is not $(KUBECTL_DEPLOY_CONTEXT)."; exit 1; fi

# Server-side apply: the MariaDB CRD is too large for client-side apply.
apply-crds: ensure-context
	kubectl apply --server-side --force-conflicts -f $(CRDS_DIR)/

apply-operator: ensure-context
	kubectl apply -f ns.yaml
	kubectl apply -n $(NAMESPACE) -f $(RESOURCES_DIR)/

apply: apply-crds apply-operator

.PHONY: render ensure-context apply-crds apply-operator apply
