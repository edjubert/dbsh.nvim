# MongoDB AWS authentication smoke test

This opt-in check uses `dbsh.backends.mongo` to resolve an AWS profile and run
`mongosh` with the generated script on stdin. It checks `ping` and an
authenticated session using `connectionStatus`. It reads no application
collections and performs no writes. It is excluded from `make test`.

## Prerequisites

- Neovim, `mongosh`, and AWS CLI v2 with `configure export-credentials`.
- An AWS profile whose IAM role is assigned to you and authorized in Atlas.
- Network access to the cluster, directly or through an existing SOCKS proxy.

## Run from fish

```fish
aws sso login --profile MyAtlasProfile
aws sts get-caller-identity --profile MyAtlasProfile

env DBSH_MONGO_HOST=cluster.example.mongodb.net \
    DBSH_MONGO_AWS_PROFILE=MyAtlasProfile \
    make mongo-aws-smoke
```

The default database is `admin`; set `DBSH_MONGO_DATABASE` to select another.
When the cluster requires a bastion, start the tunnel and provide the proxy:

```fish
ssh -Nf -o ExitOnForwardFailure=yes -D 127.0.0.1:1080 my-bastion

env DBSH_MONGO_HOST=private-endpoint.example.mongodb.net \
    DBSH_MONGO_AWS_PROFILE=MyAtlasProfile \
    DBSH_MONGO_PROXY_HOST=127.0.0.1 DBSH_MONGO_PROXY_PORT=1080 \
    make mongo-aws-smoke
```

## Output

Success prints `Mongo AWS smoke: PASS (ping and authenticated session)`.
Failure prints a generic credential-preparation message or a MongoDB error
category and exits nonzero. Raw credentials and CLI output are never printed.

An expired SSO session requires a new login. `ForbiddenException` from
`get-caller-identity` can indicate that the requested role is not assigned to
you; it does not demonstrate a `mongosh` bug. Likewise, establishing a TCP or
TLS connection does not establish that Atlas authentication has succeeded.
