# Installs or upgrades a pinned Percona Operator for MongoDB release in one namespace of your
# vcluster, then creates the database. Needs: kubectl, curl.
#
#   make resource   downloads the release's bundle.yaml (CRDs, Role, ServiceAccount, Deployment)
#   make dump       renders what `make apply` would send, without touching the cluster
#   make apply      applies the operator (server-side), waits for it, then applies the database

# The release to install. Pick one from
# https://github.com/percona/percona-server-mongodb-operator/releases and set crVersion in
# perconaservermongodb.yaml to the same version. Upgrade one minor version at a time.
PERCONA_MONGODB_VERSION ?= v1.23.1
BUNDLE_URL = https://raw.githubusercontent.com/percona/percona-server-mongodb-operator/$(PERCONA_MONGODB_VERSION)/deploy/bundle.yaml

# The operator watches only the namespace it runs in, so it and the database share one namespace.
NAMESPACE ?= my-namespace

# The kubectl context of YOUR vcluster, never the host cluster. The check below refuses to apply
# anything while another context is current.
KUBECTL_DEPLOY_CONTEXT ?= my-vcluster

# The database to create. Use perconaservermongodb-backups.yaml once its S3 Secret exists.
DATABASE ?= perconaservermongodb.yaml

.PHONY: ensure-context resource dump apply

ensure-context:
	@if [ "$$(kubectl config current-context)" != "$(KUBECTL_DEPLOY_CONTEXT)" ]; then \
	  echo "Current kubectl context is not $(KUBECTL_DEPLOY_CONTEXT). Set KUBECTL_DEPLOY_CONTEXT or switch context."; exit 1; fi

resource:
	curl -sfL "$(BUNDLE_URL)" -o bundle.yaml

dump: resource
	kubectl kustomize .

# The CRDs are too large for client-side `kubectl apply` (the last-applied annotation would
# exceed the 256 KiB limit), so the operator goes through server-side apply.
apply: ensure-context resource
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply --server-side --force-conflicts -n $(NAMESPACE) -k .
	kubectl wait --for=condition=Established --timeout=60s crd/perconaservermongodbs.psmdb.percona.com
	kubectl -n $(NAMESPACE) rollout status deployment/percona-server-mongodb-operator
	kubectl apply -n $(NAMESPACE) -f $(DATABASE)
