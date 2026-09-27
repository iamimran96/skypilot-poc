# skypilot-poc

Run a [SkyPilot](https://docs.skypilot.co) API server on a local [kind](https://kind.sigs.k8s.io) Kubernetes cluster, deployed with the official Helm chart. SkyPilot is configured to launch its workloads on the same kind cluster.

## Layout

```
infra/            local cluster + SkyPilot API server
  kind/           kind cluster configs (cluster.yaml, cluster-gpu.yaml)
  helm/           Helm values for the SkyPilot chart
  scripts/        deploy.sh / teardown.sh / setup-gpu.sh
recipes/          SkyPilot tasks to run on the cluster, one folder per recipe
requirements.txt  SkyPilot CLI client (install into a venv, see "Use it")
```

## Prerequisites

- Docker (Docker Desktop running on Windows/macOS)
- `kind`, `kubectl`, `helm`, `openssl`, `curl`
- A bash shell (Git Bash works on Windows)
- About 4 CPUs and 6 GB RAM free for Docker
- For the optional GPU cluster: an NVIDIA GPU with a current Windows driver and Docker Desktop's WSL2 backend

## Deploy

```bash
./infra/scripts/deploy.sh
```

The script:

1. Creates a kind cluster `skypilot` (1 control-plane + 1 worker) from [infra/kind/cluster.yaml](infra/kind/cluster.yaml), mapping `127.0.0.1:30050` to the ingress NodePort.
2. Installs the `skypilot/skypilot-nightly` chart into the `skypilot` namespace with overrides from [infra/helm/values-kind.yaml](infra/helm/values-kind.yaml): smaller resource requests, a NodePort ingress, in-cluster workloads, and a server config that allows only Kubernetes and exposes task ports on pod IPs.
3. Protects the API server with ingress basic auth. The password is generated on first run and saved to `.credentials` (gitignored).
4. Waits until `/api/health` responds and prints how to connect.

Re-running the script is safe: it reuses the cluster and credentials and runs `helm upgrade`.

Settings you can override with environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `CLUSTER_NAME` | `skypilot` | kind cluster name |
| `NAMESPACE` | `skypilot` | API server namespace |
| `RELEASE_NAME` | `skypilot` | Helm release name |
| `SKYPILOT_CHART` | `skypilot-nightly` | Chart name (`skypilot` for release builds) |
| `SKYPILOT_VERSION` | latest | Pin a chart version |
| `WEB_USERNAME` / `WEB_PASSWORD` | `skypilot` / generated | Basic-auth credentials |
| `HELM_TIMEOUT` | `20m` | Helm wait timeout |
| `GPU` | `0` | `1` creates the cluster from [infra/kind/cluster-gpu.yaml](infra/kind/cluster-gpu.yaml) and runs [infra/scripts/setup-gpu.sh](infra/scripts/setup-gpu.sh) |

## GPU cluster (optional)

```bash
GPU=1 ./infra/scripts/deploy.sh
```

This exposes the local NVIDIA GPU to the kind worker node (tested with Docker Desktop on WSL2 and an RTX 5060 Laptop GPU). `GPU` only takes effect when the cluster is created, so run `./infra/scripts/teardown.sh` first if a CPU-only cluster already exists. How it works:

1. The Windows driver exposes the GPU to WSL2 as `/dev/dxg` plus user-mode libraries in `/usr/lib/wsl`. Docker Desktop's VM sees both.
2. [cluster-gpu.yaml](infra/kind/cluster-gpu.yaml) labels the worker `nvidia.com/gpu.present=true` and mounts `/usr/lib/wsl` into it read-only.
3. [setup-gpu.sh](infra/scripts/setup-gpu.sh) finds nodes with that label, installs the NVIDIA container toolkit inside them, and makes the NVIDIA runtime containerd's default. It then labels each node `skypilot.co/accelerator=<gpu>` (for example `rtx5060`) and installs the NVIDIA device plugin, so pods can request `nvidia.com/gpu`.

The toolkit and containerd settings live inside the node container, so recreating the cluster means running `GPU=1 ./infra/scripts/deploy.sh` again. `setup-gpu.sh` is safe to re-run; set `GPU_LABEL` to override the detected accelerator name.

## Use it

Open the dashboard at http://127.0.0.1:30050/dashboard, or connect the CLI.

The SkyPilot CLI only runs on Linux and macOS: on native Windows it fails with `No module named 'resource'`. On Windows, use it from WSL. For WSL to reach the server on `127.0.0.1:30050`, turn on [mirrored networking](https://learn.microsoft.com/windows/wsl/networking#mirrored-mode-networking) (`networkingMode=mirrored` under `[wsl2]` in `%UserProfile%\.wslconfig`), or run `deploy.sh` from inside WSL with Docker Desktop's WSL integration enabled.

Install the client into a venv created from a WSL shell (a Windows venv will not work). Creating it on `/mnt/c` is slow because pip writes many small files across the Windows/WSL boundary; a venv on the WSL filesystem (for example `~/skypilot-venv`) installs much faster.

```bash
# from a WSL shell in the project root (PowerShell: wsl -d Ubuntu --cd /mnt/c/MLOps/skypilot-poc)
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

source .credentials
sky api login -e "http://${WEB_USERNAME}:${WEB_PASSWORD}@127.0.0.1:30050"
sky check kubernetes
sky launch --infra k8s --cpus 1 -- echo hello from skypilot
```

On a GPU cluster, `sky show-gpus --infra k8s` should list the accelerator, and `sky launch --gpus rtx5060:1 ...` runs a task on it.

### Clusters and jobs

A SkyPilot *cluster* is not a second Kubernetes cluster: it is a named group of pods that SkyPilot creates inside the kind cluster. `sky launch -c <name> task.yaml` creates one and it stays up until `sky down <name>`. A *managed job* (`sky jobs launch -n <name> task.yaml`) creates the pods, runs the task and deletes them when it finishes, so there is nothing to clean up.

Pass the task file path relative to your current directory. If the file is not found, SkyPilot runs the argument as a shell command and the job fails with `task.yaml: command not found` (exit code 127).

## Recipes

[recipes/](recipes/README.md) has ready-to-run tasks: hello world, MNIST training (CPU, or the GPU when one is available), a managed job that recovers from pod failures using a PVC checkpoint, 2-node PyTorch DDP, a FastAPI model server, and a vLLM GPU server that still needs its accelerator request updated for the local GPU.

## Tear down

```bash
./infra/scripts/teardown.sh
```
