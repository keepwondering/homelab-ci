# homelab-ci

Shared GitHub Actions automation for deploying trusted projects into the
`keepwondering` homelab.

## Deployment action

The repository's composite action owns the shared deployment infrastructure
while allowing the calling job to retain access to its GitHub Environment
secrets. The caller must check out the requested revision first and provide
`WG_CONF_B64`, `KUBECONFIG_B64`, and `SOPS_AGE_KEY` through the action step's
environment.

## Legacy reusable workflow

`.github/workflows/deploy.yaml` remains available for same-owner callers that
can pass secrets across the reusable-workflow boundary. The composite action is
required when deployment credentials are stored as GitHub Environment secrets
in a repository owned outside `keepwondering`.

Both entrypoints own the shared deployment infrastructure:

- selecting and checking out the requested revision
- authenticating to GitHub Container Registry
- installing pinned Kubernetes, Helm, Age, and SOPS versions
- opening and closing the WireGuard tunnel
- configuring Kubernetes access
- invoking an application-owned deployment script
- optionally waiting for matching Kubernetes deployments

Application-specific Helm values, image mappings, secret decryption, migrations,
and validation remain in each application repository.

### Application contract

By default, a consuming repository provides `scripts/ci-deploy.sh`. The workflow
invokes it as:

```shell
bash scripts/ci-deploy.sh "$DEPLOY_SHA" "$DEPLOY_ENVIRONMENT"
```

The script also receives these environment variables:

- `DEPLOY_SHA`: full checked-out commit SHA
- `DEPLOY_ENVIRONMENT`: environment supplied by the caller
- `DEPLOY_NAMESPACE`: Kubernetes namespace supplied by the caller
- `KUBECONFIG`: path to the temporary kubeconfig
- `SOPS_AGE_KEY`: Age private key from the selected GitHub environment
- `GITHUB_TOKEN`: available through the standard GitHub Actions context when needed

The script must fail with a non-zero exit code if validation or deployment fails.
It should be deterministic and safe to retry.

### Caller example

```yaml
name: Deploy

on:
  workflow_dispatch:
    inputs:
      target:
        description: Environment to deploy
        type: choice
        required: true
        options: [qa, prod]
        default: qa
      sha:
        description: Commit SHA to deploy
        type: string
        required: false
        default: ""

permissions:
  contents: read
  packages: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: ${{ inputs.target }}
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ inputs.sha || github.sha }}
      - uses: keepwondering/homelab-ci@v1
        with:
          environment: ${{ inputs.target }}
          deploy_sha: ${{ inputs.sha || github.sha }}
          namespace: wims
          rollout_selector: app.kubernetes.io/name=wims
        env:
          GITHUB_TOKEN: ${{ github.token }}
          WG_CONF_B64: ${{ secrets.WG_CONF_B64 }}
          KUBECONFIG_B64: ${{ secrets.KUBECONFIG_B64 }}
          SOPS_AGE_KEY: ${{ secrets.SOPS_AGE_KEY }}
```

Pin consumers to an immutable commit SHA until a reviewed `v1` release exists.

## Required repository settings

Each caller needs:

1. Read access to this public repository from GitHub Actions.
2. GitHub Environments such as `qa` and `prod`, with `WG_CONF_B64`,
   `KUBECONFIG_B64`, and `SOPS_AGE_KEY` secrets and production approvals where
   appropriate.
3. Read access to its GitHub Container Registry packages.

Only trusted repositories should be granted access because their deployment
scripts execute while connected to the homelab. Prefer the composite action for
cross-owner callers because environment secrets do not cross a reusable-workflow
boundary.

### Bootstrap an application environment

An administrator can create namespace-scoped Kubernetes credentials and upload
all required GitHub Environment secrets with:

```shell
scripts/setup-deploy-environment.sh \
  --repo devtin/stillwondering.io \
  --environment production \
  --namespace stillwondering \
  --context homelab-admin \
  --wireguard-config /secure/path/wg0.conf \
  --age-key ~/.config/sops/age/keys.txt
```

The helper displays its targets and asks for confirmation before changing the
cluster or GitHub. It creates a namespace, ServiceAccount, namespaced Role and
RoleBinding, and a dedicated service-account token. It then builds a temporary
kubeconfig, stores `WG_CONF_B64`, `KUBECONFIG_B64`, and `SOPS_AGE_KEY` in the
selected GitHub Environment, and removes the temporary kubeconfig.

The generated credential is intentionally limited to common Helm-managed
namespaced resources, including workloads, Services, Secrets, ConfigMaps,
cert-manager Certificates, and Traefik routes and middleware. Review the Role in
the helper before using it for an application that needs other resource types.

The helper uses a long-lived service-account token because GitHub-hosted runners
cannot request an in-cluster token. Delete the generated token Secret before
re-running the helper when that credential must be rotated, or replace it with
workload identity when the cluster supports an external OIDC trust relationship.

## Versioning

Breaking input or contract changes require a new major version. Consumers may use
a moving major tag such as `v1` after releases are established, or pin a full
commit SHA for maximum reproducibility.
