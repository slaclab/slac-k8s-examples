# Logging users in to your application (s3df-authnz or Dex OIDC)

A web application on S3DF can put the SLAC login in front of its users in two ways. With
s3df-authnz, four annotations on an HTTPRoute make the gateway check the login before a request
reaches the application, which then reads the user from request headers. With a Dex client, the
application itself is an OpenID Connect (OIDC) client of S3DF Dex, `https://dex.slac.stanford.edu`:
it sends users to the login, receives their tokens and keeps its own sessions. Use s3df-authnz
unless the application already speaks OIDC or must run the login itself.

Both depend on the platform team. s3df-authnz needs the gateway switch for your vcluster and an
approved hostname; a Dex client must be registered by the platform team. The example on this page
also needs the External Secrets switch. See
[Your vcluster](../vcluster/README.md#features-and-allowlists-the-platform-sets).

## Choosing

| | s3df-authnz on an HTTPRoute | A Dex client of your own |
|---|---|---|
| Who runs the login | The gateway, before the request reaches your application | Your application |
| Code in your application | None: read the `X-Auth-Request-*` headers | An OIDC library, a callback URL and session handling |
| Coact groups | Checked by the gateway, and passed in a header | Not available: Dex's tokens carry no groups |
| Way in | An HTTPRoute, with the gateway switch | Any: HTTPRoute, Ingress or LoadBalancer Service |
| Scripts and command line tools | Send a token from `s3df login` | Run their own OIDC flow against Dex |
| What you ask the platform team for | The gateway switch and a hostname | A client, with its redirect URIs |
| Guide | [HTTPRoutes with S3DF login](../httproutes/README.md) | This page |

Argo CD on S3DF, for example, signs users in with a Dex client of its own: see
[GitOps into a vcluster](../../advanced/gitops-argocd/README.md). On an Ingress without the
gateway switch, the platform's other login is Vouch: see
[Ingress](../ingresses/README.md#vouch-login).

## How a Dex login works

1. Your application sends the browser to Dex with its client ID, a redirect URI and the scopes
   it wants.
2. Dex sends the user to the SLAC login. Dex shows no consent screen, so the user goes straight
   back to your application after signing in.
3. Dex returns the browser to the redirect URI with a code. It accepts only redirect URIs that
   are registered for the client, character for character.
4. Your application exchanges the code for an ID token and an access token at Dex's token
   endpoint, with its client ID and secret. Dex is a SLAC host, so pods reach it directly,
   without the HTTP proxy. Every network isolation profile allows it: the platform's baseline
   policy admits `dex.slac.stanford.edu` on port 443.
5. Your application checks the ID token's signature with Dex's keys and reads the user from its
   claims.

Dex lets every SLAC account sign in to every client. A token proves who the user is, not that
the user may use your application: decide that in your application, by the `email` claim.

## S3DF Dex

| Setting | Value | What it is for |
|---|---|---|
| Issuer | `https://dex.slac.stanford.edu` | The one setting most OIDC libraries need. They read the rest from discovery |
| Discovery | `https://dex.slac.stanford.edu/.well-known/openid-configuration` | Endpoints, keys, scopes and grants |
| Authorization, token, keys, userinfo | `/auth`, `/token`, `/keys`, `/userinfo` below the issuer | The endpoints that discovery lists |
| Client authentication | `client_secret_basic` or `client_secret_post` | How a confidential client sends its secret to the token endpoint |
| PKCE | `S256` | For public clients, and as extra protection for confidential ones. Dex also accepts `plain`, which protects less |
| Grants | Authorization code, refresh token, device code, token exchange | The device code grant suits command line tools |
| ID and access tokens | Valid for 12 hours | |
| Refresh tokens | Refused 12 hours after sign-in | No refresh succeeds after 12 hours: the user signs in again |

The development login stack has its own Dex, `https://dex-dev.slac.stanford.edu`, with its own
list of clients and 1-hour tokens. It signs users in through a test instance of the SLAC login,
and its settings differ from production's: test a client against the production Dex before you
rely on it.

## Scopes and claims

| Scope | Claims | Content |
|---|---|---|
| `openid` | `iss`, `sub`, `aud`, `exp`, `iat` | `aud` is your client ID. `sub` is Dex's identifier for the user: opaque, not the username |
| `email` | `email`, `email_verified` | `<username>@slac.stanford.edu`; `email_verified` is `true` |
| `profile` | `name` | The SLAC username |
| `groups` | `groups` | Never present from the production Dex: the SLAC login passes it no groups |
| `offline_access` | A refresh token | It ends with the login, 12 hours after sign-in |

Identify users by `email`. It is also the username that your vcluster's API server and Argo CD
on S3DF use, so one list of users serves all three. For Coact groups or POSIX identity, use
s3df-authnz: its headers carry them.

## Requesting a client

The platform team registers clients: Dex's client list is one configuration for all of S3DF. Ask
s3df-help, and send:

| What to send | Example | Why |
|---|---|---|
| Your vcluster and the application | `my-vcluster`, my-app | The client is named for the application |
| Each redirect URI, exactly | `https://my-app.slac.stanford.edu/oauth2/callback` | Dex compares scheme, host, port and path as written. Your application's documentation gives the path |
| Confidential or public | Confidential for an application with a server; public for a command line tool or a browser-only application | A public client has no secret, so it uses PKCE or the device code grant |
| Where to keep the secret | Under your vcluster's Vault path, for example `secret/my-facility/my-vcluster/my-app/oidc` | Your vcluster's store reads only its own path, so a secret kept anywhere else does not reach your vcluster |
| Whether you also need a development client | | The development Dex has a separate client list |

The platform team adds the client to Dex, keeps its secret in Vault and tells you the client ID.
Dex reads the secret from Vault only when the platform team applies its configuration, so ask
them to rotate it: a value you change yourself in Vault never reaches Dex.

Don't use your vcluster's own login client, `vcluster--<name>`, for an application. The login
page prints its secret to every user, and its ID tokens are kubectl credentials for your
vcluster: every token your application held would let its holder act in your vcluster as that
user.

## Getting the client secret into your vcluster

[`externalsecret-oidc-client.yaml`](externalsecret-oidc-client.yaml) copies the client ID and
secret from Vault into the Secret `my-app-oidc`, and
[`deployment.yaml`](deployment.yaml) passes them to the application as environment variables,
next to the issuer and the redirect URI. The secret never appears in git or in the image. See
[External Secrets](../secrets/external-secrets/README.md) for the store, refresh and the other
fields.

- If the platform team keeps the secret outside your vcluster's path and gives your vcluster read
  access to it, the annotation cannot choose your store from that path. Drop the annotation and
  set `secretStoreRef` to your vcluster's ClusterSecretStore, `<facility>-<name>`.
- Without the External Secrets switch, use one of the other ways to make a Secret from Vault:
  see [Secrets](../secrets/README.md).
- Environment variables are read when the container starts. After the platform team rotates the
  secret, restart the pods once the Secret has refreshed.

## Examples

| File | What it shows |
|---|---|
| [`externalsecret-oidc-client.yaml`](externalsecret-oidc-client.yaml) | The client ID and secret from `secret/my-facility/my-vcluster/my-app/oidc` in Secret `my-app-oidc` |
| [`deployment.yaml`](deployment.yaml) | my-app with the issuer, redirect URI and scopes as settings and the client credentials from `my-app-oidc` |

The manifests set no namespace. Apply them to a namespace of your own with `-n`: platform policy
forbids the vcluster's `default` namespace. The image, `ghcr.io/my-org/my-app:1.0.0`, and the
variable names stand for your application's own. To publish the application, add an
[HTTPRoute](../httproutes/README.md) or an [Ingress](../ingresses/README.md) for
`my-app.slac.stanford.edu` without a login annotation: the application runs the login itself.

```bash
kubectl apply -n my-namespace -f externalsecret-oidc-client.yaml -f deployment.yaml
```

## Mistakes that break a login or let too many in

| Mistake | Result |
|---|---|
| A redirect URI that differs from the registered one: `http` for `https`, another path, a trailing slash, another hostname | Dex answers `Unregistered redirect_uri.` and the login stops. Ask the platform team to register the exact URI |
| The production client ID against the development Dex, or the reverse | Dex answers `Invalid client_id.` Each Dex has its own clients |
| Access decided by the `groups` claim | The claim is never present, so a check for a group admits no one, and a check for "no forbidden group" admits everyone. Use s3df-authnz for Coact groups |
| No check of who the user is, because Dex has already logged them in | Every SLAC account can use the application. Check `email` against your own list |
| Your vcluster's login client, `vcluster--<name>`, as the application's client | Its secret is printed to every user, and the tokens your application handles are kubectl credentials for your vcluster |
| The client secret in a manifest, ConfigMap or image | Everyone who can read the repository or pull the image has it. Keep it in Vault and use an ExternalSecret |
| Changing the client secret in Vault yourself | Dex keeps the old secret until the platform team applies its configuration again. After the next refresh your application sends the new one, and every login fails. Ask the platform team to rotate it |
| Sessions longer than 12 hours, relying on the refresh token | The refresh fails 12 hours after sign-in. Send the user to the login again |
| Fetching discovery or Dex's keys for every request | Dex limits each client address to a few requests per second and answers `429`. Pods leave the cluster with their node's address, so pods on one node share the limit. Cache discovery and keys; most OIDC libraries do |

## Checking

```bash
# Dex's settings, from any machine: issuer, endpoints, scopes and grants.
curl -s https://dex.slac.stanford.edu/.well-known/openid-configuration

# Dex is reachable from a pod in your vcluster: expect 200.
kubectl run -n my-namespace dex-check --rm -it --restart=Never --image=curlimages/curl:8.13.0 -- \
  curl -s -o /dev/null -w '%{http_code}\n' https://dex.slac.stanford.edu/.well-known/openid-configuration

# The client secret has reached your vcluster: STATUS SecretSynced, READY True.
kubectl get externalsecret my-app-oidc -n my-namespace
```

Upstream references: [Dex](https://dexidp.io/docs/) and the
[OpenID Connect Core specification](https://openid.net/specs/openid-connect-core-1_0.html).
