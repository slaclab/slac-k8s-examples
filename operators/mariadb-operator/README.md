# mariadb operator manifest and mariadb database manifest
The content is devided in two folders, `operator` and `database`.

## operator

While is straightforward to install the mariadb operator via helm, we strongly suggest to know what indeed is being applied in the cluster. Thats why we strongly recommend the use of kubectl slice plugging to render the different crds and resources that comes from the operator. The `Makefile` within the operator directory will automatically pull the mariadb operator `--version 0.38.1` and split the rendered manifest between the ones that are namespaced and the ones that are not namespaced. The name of the namespace where the operator will run is `mariadb-system`. A successful operator will create 3 different deployments called `mariadb-operator, mariadb-operator-cert-controller, mariadb-operator-webhook` Once 3 deployments are ready you can proceed to apply the different manifest for the database

## database

The manifests under `database` are intended to be apply only after a successful operator. Its has a Makefile that get some secrets from vault (mandatory are root and the user for the database). Access to vault where the secrets are stored needs to be granted before creating the secrets, unless the user is willing to do it manually.

Also is recommended for resiliency to create backups that are stored on s3, where secrets for the access_key and secret_key needs to be populated.

`mariadb.yaml` has automatic monitoring that comes from a deployment from the image `prom/mysqld-exporter:v0.17.2`

The instance is deployed using kustomize which will render all what will be applied in the cluster/vcluster.
