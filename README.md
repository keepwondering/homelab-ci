# homelab-ci

Reusable GitHub Actions workflows for deploying trusted projects into the
`keepwondering` homelab.

## Helm deployment workflow

`.github/workflows/deploy.yaml` owns the shared deployment infrastructure:

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
- `SOPS_AGE_KEY`: Age private key supplied by the caller
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
    uses: keepwondering/homelab-ci/.github/workflows/deploy.yaml@v1
    with:
      environment: ${{ inputs.target }}
      deploy_sha: ${{ inputs.sha || github.sha }}
      namespace: wims
      rollout_selector: app.kubernetes.io/name=wims
    secrets:
      wireguard_config: ${{ secrets.WG_CONF_B64 }}
      kubeconfig: ${{ secrets.KUBECONFIG_B64 }}
      sops_age_key: ${{ secrets.SOPS_AGE_KEY }}
```

Pin consumers to an immutable commit SHA until a reviewed `v1` release exists.

## Required repository settings

Each caller needs:

1. Access to this private repository through the organization's GitHub Actions
   access settings.
2. `WG_CONF_B64`, `KUBECONFIG_B64`, and `SOPS_AGE_KEY` secrets, preferably as
   organization secrets restricted to approved repositories.
3. GitHub Environments such as `qa` and `prod`, with production approvals where
   appropriate.
4. Read access to its GitHub Container Registry packages.

Only trusted repositories should be granted access because their deployment
scripts execute while connected to the homelab.

## Versioning

Breaking input or contract changes require a new major version. Consumers may use
a moving major tag such as `v1` after releases are established, or pin a full
commit SHA for maximum reproducibility.
