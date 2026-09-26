#!/usr/bin/env bash
# Create a local kind cluster and deploy the SkyPilot API server on it via Helm.
#
# Usage:
#   ./infra/scripts/deploy.sh         # create cluster (if missing) + install/upgrade SkyPilot
#
# Configuration (environment variables, all optional):
#   CLUSTER_NAME        kind cluster name                      (default: skypilot)
#   NAMESPACE           namespace for the API server           (default: skypilot)
#   RELEASE_NAME        Helm release name                      (default: skypilot)
#   SKYPILOT_CHART      chart in the skypilot repo             (default: skypilot-nightly)
#   SKYPILOT_VERSION    chart version; empty = latest          (default: empty)
#   WEB_USERNAME        basic-auth user for the API server     (default: skypilot)
#   WEB_PASSWORD        basic-auth password; generated and saved to .credentials if unset
#   HELM_TIMEOUT        how long to wait for the release       (default: 20m)
set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(dirname "$INFRA_DIR")"
CRED_FILE="${REPO_DIR}/.credentials"

CLUSTER_NAME="${CLUSTER_NAME:-skypilot}"
NAMESPACE="${NAMESPACE:-skypilot}"
RELEASE_NAME="${RELEASE_NAME:-skypilot}"
SKYPILOT_CHART="${SKYPILOT_CHART:-skypilot-nightly}"
SKYPILOT_VERSION="${SKYPILOT_VERSION:-}"
HELM_TIMEOUT="${HELM_TIMEOUT:-20m}"
HOST_PORT=30050
KUBE_CONTEXT="kind-${CLUSTER_NAME}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

check_prereqs() {
  log "Checking prerequisites"
  local missing=()
  for tool in docker kind kubectl helm openssl curl; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  [[ ${#missing[@]} -eq 0 ]] || fail "Missing tools: ${missing[*]}"
  docker info >/dev/null 2>&1 || fail "Docker daemon is not running. Start Docker Desktop and retry."
}

load_credentials() {
  # Reuse previously generated credentials so re-runs don't rotate the password.
  if [[ -z "${WEB_PASSWORD:-}" && -f "$CRED_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CRED_FILE"
  fi
  WEB_USERNAME="${WEB_USERNAME:-skypilot}"
  if [[ -z "${WEB_PASSWORD:-}" ]]; then
    WEB_PASSWORD="$(openssl rand -hex 12)"
    log "Generated API server password (saved to .credentials)"
  fi
  printf 'WEB_USERNAME=%s\nWEB_PASSWORD=%s\n' "$WEB_USERNAME" "$WEB_PASSWORD" > "$CRED_FILE"
  chmod 600 "$CRED_FILE" 2>/dev/null || true
}

create_cluster() {
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    log "kind cluster '$CLUSTER_NAME' already exists, reusing it"
  else
    log "Creating kind cluster '$CLUSTER_NAME'"
    kind create cluster --name "$CLUSTER_NAME" --config "${INFRA_DIR}/kind/cluster.yaml" --wait 5m
  fi
  kubectl --context "$KUBE_CONTEXT" wait --for=condition=Ready nodes --all --timeout=5m
}

deploy_skypilot() {
  log "Adding SkyPilot Helm repo"
  helm repo add skypilot https://helm.skypilot.co --force-update >/dev/null
  helm repo update skypilot >/dev/null

  # Ingress basic auth expects an htpasswd line; openssl produces the same apr1 hash.
  local auth_string
  auth_string="${WEB_USERNAME}:$(openssl passwd -apr1 "$WEB_PASSWORD")"

  local version_args=(--devel)
  [[ -n "$SKYPILOT_VERSION" ]] && version_args=(--version "$SKYPILOT_VERSION")

  log "Installing SkyPilot chart skypilot/${SKYPILOT_CHART} (this pulls a large image, may take a while)"
  helm upgrade --install "$RELEASE_NAME" "skypilot/${SKYPILOT_CHART}" "${version_args[@]}" \
    --kube-context "$KUBE_CONTEXT" \
    --namespace "$NAMESPACE" --create-namespace \
    --values "${INFRA_DIR}/helm/values-kind.yaml" \
    --set-string ingress.authCredentials="$auth_string" \
    --wait --timeout "$HELM_TIMEOUT"
}

verify() {
  local endpoint="http://127.0.0.1:${HOST_PORT}"
  log "Waiting for API server health at ${endpoint}/api/health"
  for _ in $(seq 1 60); do
    if curl -fsS -u "${WEB_USERNAME}:${WEB_PASSWORD}" "${endpoint}/api/health" >/dev/null 2>&1; then
      log "SkyPilot API server is healthy"
      cat <<EOF

  Dashboard : ${endpoint}/dashboard
  Username  : ${WEB_USERNAME}
  Password  : stored in .credentials

  Connect the SkyPilot CLI (pip install "skypilot-nightly[kubernetes]"):
    source .credentials
    sky api login -e "http://\${WEB_USERNAME}:\${WEB_PASSWORD}@127.0.0.1:${HOST_PORT}"
    sky check kubernetes

EOF
      return 0
    fi
    sleep 5
  done
  fail "API server did not become healthy. Check: kubectl --context $KUBE_CONTEXT -n $NAMESPACE get pods"
}

check_prereqs
load_credentials
create_cluster
deploy_skypilot
verify
