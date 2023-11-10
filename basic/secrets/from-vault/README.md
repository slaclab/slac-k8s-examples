
Simple example of maintaing secrets in vault and syncing at deployment time that secret with that in kubernetes.
===

We maintain a Makefile and a kustomization.yaml to basically:
- retrieve the secret from vault using the Makefile
- store them temporarily in a directory (which should of course be .gitignore'd) at etc/.secrets/
- use kustomization.yaml to define/map these secrets to actual kubernetes secrets
- when `kubectl apply -k` is ran, the secrets are synchronised

Whilst this example is relatively simple.
- it will not maintain synchronisation of the passwords without running `kubectl apply -k`
- extensible to keep the passwords anywhere (can just write individual files to etc/.secrets/)
- one should NOT store passwords directly in any manifest (or things that are revision controlled). use .gitignore etc.
- keeping the passwords on the filesystem of course poses security risks, so ensure permissions etc are enforced


