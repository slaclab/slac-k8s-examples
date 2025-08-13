# serviceMonitor
Kubernetes resource that allows Prometheus to scrape a desired Service.

## Description
This folder contains the neccessary resources to deploy and monitor an example application:

- Deployment
- Service
- ServiceMonitor

### Deployment
Deploys an example app with the quay.io/brancz/prometheus-example-app image, which has a port at 8080

### Service
Deploys a service that listens in port 8080

### serviceMonitor
Deploys a serviceMonitor that will scrape label `app: example-app`, which matches the service selector and label. 


**IMPORTANT**
For a serviceMonitor to be scraped and picked by prometheus, it needs the required labels:
```
metadata:
  labels:
    release: sdf-k8s01
```
