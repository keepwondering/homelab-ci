#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  setup-deploy-environment.sh \
    --repo OWNER/REPO \
    --environment NAME \
    --namespace NAME \
    --wireguard-config PATH \
    --age-key PATH \
    [--context NAME] \
    [--service-account NAME] \
    [--yes]

Creates namespace-scoped Kubernetes deployment credentials and stores these
GitHub Environment secrets without writing credentials to the repository:

  WG_CONF_B64, KUBECONFIG_B64, SOPS_AGE_KEY

The current kubectl context is used unless --context is supplied.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_value() {
  [[ $# -ge 2 && -n "$2" ]] || die "$1 requires a value"
}

repo=""
environment=""
namespace=""
wireguard_config=""
age_key=""
context=""
service_account=""
assume_yes=false

while (($#)); do
  case "$1" in
    --repo)
      require_value "$@"
      repo="$2"
      shift 2
      ;;
    --environment)
      require_value "$@"
      environment="$2"
      shift 2
      ;;
    --namespace)
      require_value "$@"
      namespace="$2"
      shift 2
      ;;
    --wireguard-config)
      require_value "$@"
      wireguard_config="$2"
      shift 2
      ;;
    --age-key)
      require_value "$@"
      age_key="$2"
      shift 2
      ;;
    --context)
      require_value "$@"
      context="$2"
      shift 2
      ;;
    --service-account)
      require_value "$@"
      service_account="$2"
      shift 2
      ;;
    --yes)
      assume_yes=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ "$repo" == */* ]] || die "--repo must use OWNER/REPO format"
[[ -n "$environment" ]] || die "--environment is required"
[[ -n "$namespace" ]] || die "--namespace is required"
[[ -f "$wireguard_config" ]] || die "WireGuard config not found: $wireguard_config"
[[ -f "$age_key" ]] || die "Age key not found: $age_key"
[[ "$namespace" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "invalid Kubernetes namespace: $namespace"

for command in kubectl gh base64 mktemp; do
  command -v "$command" >/dev/null || die "required command not found: $command"
done

gh auth status >/dev/null 2>&1 || die "authenticate first with: gh auth login"
gh repo view "$repo" >/dev/null 2>&1 || die "cannot access GitHub repository: $repo"

if [[ -z "$context" ]]; then
  context="$(kubectl config current-context)"
fi
kubectl config get-contexts "$context" >/dev/null 2>&1 || die "kubectl context not found: $context"

if [[ -z "$service_account" ]]; then
  service_account="${namespace}-ci"
fi
[[ "$service_account" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "invalid service account name: $service_account"
token_secret="${service_account}-token"

grep -q '^\[Interface\]' "$wireguard_config" || die "WireGuard config is missing [Interface]"
grep -q '^[[:space:]]*PrivateKey[[:space:]]*=' "$wireguard_config" || die "WireGuard config is missing PrivateKey"
grep -q 'AGE-SECRET-KEY-' "$age_key" || die "Age key file does not contain a secret key"

cat <<EOF
This will configure deployment access for:
  GitHub repository:  $repo
  GitHub environment: $environment
  Kubernetes context: $context
  Namespace:          $namespace
  Service account:    $service_account
EOF

if [[ "$assume_yes" != true ]]; then
  if [[ ! -t 0 ]]; then
    die "confirmation requires a terminal; rerun with --yes for non-interactive use"
  fi
  read -r -p "Continue? [y/N] " answer
  [[ "$answer" == "y" || "$answer" == "Y" ]] || die "cancelled"
fi

kubectl --context "$context" apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $namespace
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $service_account
  namespace: $namespace
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: $service_account
  namespace: $namespace
rules:
  - apiGroups: [""]
    resources: ["configmaps", "secrets", "services"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets", "daemonsets", "replicasets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["batch"]
    resources: ["jobs", "cronjobs"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["cert-manager.io"]
    resources: ["certificates"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["traefik.io", "traefik.containo.us"]
    resources: ["ingressroutes", "middlewares"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: $service_account
  namespace: $namespace
subjects:
  - kind: ServiceAccount
    name: $service_account
    namespace: $namespace
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: $service_account
---
apiVersion: v1
kind: Secret
metadata:
  name: $token_secret
  namespace: $namespace
  annotations:
    kubernetes.io/service-account.name: $service_account
type: kubernetes.io/service-account-token
EOF

temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT
chmod 700 "$temporary_directory"
ci_kubeconfig="$temporary_directory/kubeconfig"

for _ in {1..30}; do
  token="$(kubectl --context "$context" --namespace "$namespace" get secret "$token_secret" -o jsonpath='{.data.token}' 2>/dev/null || true)"
  ca_data="$(kubectl --context "$context" --namespace "$namespace" get secret "$token_secret" -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)"
  [[ -n "$token" && -n "$ca_data" ]] && break
  sleep 1
done
[[ -n "${token:-}" && -n "${ca_data:-}" ]] || die "timed out waiting for the service account token"

server="$(kubectl config view --context "$context" --minify -o jsonpath='{.clusters[0].cluster.server}')"
cluster_name="$(kubectl config view --context "$context" --minify -o jsonpath='{.clusters[0].name}')"
token="$(printf '%s' "$token" | base64 --decode)"

KUBECONFIG="$ci_kubeconfig" kubectl config set-cluster "$cluster_name" \
  --server "$server" \
  --certificate-authority <(printf '%s' "$ca_data" | base64 --decode) \
  --embed-certs=true >/dev/null
KUBECONFIG="$ci_kubeconfig" kubectl config set-credentials "$service_account" --token "$token" >/dev/null
KUBECONFIG="$ci_kubeconfig" kubectl config set-context "$service_account@$cluster_name" \
  --cluster "$cluster_name" \
  --user "$service_account" \
  --namespace "$namespace" >/dev/null
KUBECONFIG="$ci_kubeconfig" kubectl config use-context "$service_account@$cluster_name" >/dev/null
chmod 600 "$ci_kubeconfig"
unset token ca_data

KUBECONFIG="$ci_kubeconfig" kubectl auth can-i list deployments --namespace "$namespace" >/dev/null \
  || die "generated credentials cannot list deployments in $namespace"

gh api --method PUT "repos/$repo/environments/$environment" --silent
base64 < "$wireguard_config" | gh secret set WG_CONF_B64 --repo "$repo" --env "$environment"
base64 < "$ci_kubeconfig" | gh secret set KUBECONFIG_B64 --repo "$repo" --env "$environment"
gh secret set SOPS_AGE_KEY --repo "$repo" --env "$environment" < "$age_key"

echo "Configured $repo environment '$environment' with dedicated credentials for namespace '$namespace'."
