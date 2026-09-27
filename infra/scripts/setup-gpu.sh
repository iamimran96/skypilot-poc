#!/usr/bin/env bash
# Enable the local NVIDIA GPU inside a kind cluster created from
# infra/kind/cluster-gpu.yaml. Safe to re-run.
#
# For every node labelled nvidia.com/gpu.present=true it:
#   1. installs the NVIDIA container toolkit inside the node container,
#   2. makes the NVIDIA runtime containerd's default,
#   3. labels the node for SkyPilot (skypilot.co/accelerator=<gpu>),
# then installs the NVIDIA device plugin so pods can request nvidia.com/gpu.
#
# Configuration (environment variables, all optional):
#   CLUSTER_NAME        kind cluster name                      (default: skypilot)
#   GPU_LABEL           SkyPilot accelerator name, lowercase   (default: detected, e.g. rtx5060)
#   DEVICE_PLUGIN_VERSION  nvidia-device-plugin chart version  (default: latest)
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-skypilot}"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"
DEVICE_PLUGIN_VERSION="${DEVICE_PLUGIN_VERSION:-}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

kc() { kubectl --context "$KUBE_CONTEXT" "$@"; }

# Runs inside each GPU node container.
read -r -d '' NODE_SETUP <<'EOF' || true
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# WSL2 (Docker Desktop on Windows) ships the user-mode driver in /usr/lib/wsl/lib.
if [ -d /usr/lib/wsl/lib ]; then
  echo /usr/lib/wsl/lib > /etc/ld.so.conf.d/wsl.conf
  ldconfig
fi

if ! command -v nvidia-ctk >/dev/null 2>&1; then
  apt-get update -qq >/dev/null
  apt-get install -y -qq curl gnupg ca-certificates >/dev/null
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update -qq >/dev/null
  apt-get install -y -qq nvidia-container-toolkit >/dev/null
fi

nvidia-container-cli info >/dev/null || { echo "GPU not visible in node" >&2; exit 1; }

if ! containerd config dump 2>/dev/null | grep -q "default_runtime_name = 'nvidia'"; then
  nvidia-ctk runtime configure --runtime=containerd --set-as-default >/dev/null
  systemctl restart containerd
fi

# Print the GPU model for labelling, e.g. "NVIDIA GeForce RTX 5060 Laptop GPU".
nvidia-container-cli info | sed -n 's/^Model:[[:space:]]*//p' | head -1
EOF

# "NVIDIA GeForce RTX 5060 Laptop GPU" -> "rtx5060"
gpu_label_from_model() {
  local model
  model="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
  model="${model#nvidia }"; model="${model#geforce }"
  model="${model% gpu}"; model="${model% laptop}"
  echo "$model" | tr -d ' -'
}

log "Finding GPU nodes in cluster '$CLUSTER_NAME'"
mapfile -t nodes < <(kc get nodes -l nvidia.com/gpu.present=true -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
[[ ${#nodes[@]} -gt 0 ]] || fail "No nodes labelled nvidia.com/gpu.present=true. Create the cluster from infra/kind/cluster-gpu.yaml."

for node in "${nodes[@]}"; do
  log "Configuring NVIDIA runtime on $node"
  model="$(docker exec "$node" bash -c "$NODE_SETUP" | tail -1)"
  [[ -n "$model" ]] || fail "Could not detect GPU model on $node"
  label="${GPU_LABEL:-$(gpu_label_from_model "$model")}"
  log "$node: $model -> skypilot.co/accelerator=$label"
  kc label node "$node" "skypilot.co/accelerator=$label" --overwrite >/dev/null
done

log "Installing NVIDIA device plugin"
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin --force-update >/dev/null
helm repo update nvdp >/dev/null
version_args=()
[[ -n "$DEVICE_PLUGIN_VERSION" ]] && version_args=(--version "$DEVICE_PLUGIN_VERSION")
helm upgrade --install nvdp nvdp/nvidia-device-plugin "${version_args[@]}" \
  --kube-context "$KUBE_CONTEXT" \
  --namespace nvidia-device-plugin --create-namespace \
  --wait --timeout 5m >/dev/null

log "Waiting for nodes to advertise nvidia.com/gpu"
for _ in $(seq 1 30); do
  gpus="$(kc get nodes -l nvidia.com/gpu.present=true -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{" "}{end}')"
  if [[ "$gpus" =~ [1-9] ]]; then
    kc get nodes -l nvidia.com/gpu.present=true \
      -o custom-columns='NODE:.metadata.name,GPUS:.status.allocatable.nvidia\.com/gpu,ACCELERATOR:.metadata.labels.skypilot\.co/accelerator'
    exit 0
  fi
  sleep 2
done
fail "Device plugin is running but no node reports nvidia.com/gpu. Check: kubectl --context $KUBE_CONTEXT -n nvidia-device-plugin logs -l app.kubernetes.io/name=nvidia-device-plugin"
