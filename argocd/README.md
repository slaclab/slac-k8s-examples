# Argo CD (superseded)

This directory held an early Argo CD self-install: a rendered Helm chart for one vcluster, with
another project's hostname and secrets path, a deprecated `kubernetes.io/ingress.class`
annotation and a Dex login that required a `groups` claim, which S3DF Dex does not send. It
was removed because it no longer works as a template.

To deploy into your vcluster from git, follow
[GitOps into a vcluster (Argo CD)](../advanced/gitops-argocd/README.md). It covers Argo CD
installed by the platform team, installing it yourself with the Helm chart values that work on
S3DF, and an example Application.
