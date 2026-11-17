.PHONY: apply delete

# The namespace to deploy into: never the vcluster's default namespace.
NAMESPACE ?= my-namespace

apply:
	kubectl apply -k . -n $(NAMESPACE)

# Frees the GPU: the pod holds it for as long as it exists.
delete:
	kubectl delete -k . -n $(NAMESPACE)
