# skypilot-poc

Run a [SkyPilot](https://docs.skypilot.co) API server on a local [kind](https://kind.sigs.k8s.io) Kubernetes cluster, deployed with the official Helm chart. SkyPilot is configured to launch its workloads on the same kind cluster.

## Layout

```
infra/            local cluster + SkyPilot API server
  kind/           kind cluster config
  helm/           Helm values for the SkyPilot chart
  scripts/        deploy.sh / teardown.sh
recipes/          SkyPilot tasks to run on the cluster, one folder per recipe
```

## Prerequisites

- Docker (Docker Desktop running on Windows/macOS)
- `kind`, `kubectl`, `helm`, `openssl`, `curl`
- A bash shell (Git Bash works on Windows)
- About 4 CPUs and 6 GB RAM free for Docker

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

## Use it

Open the dashboard at http://127.0.0.1:30050/dashboard, or connect the CLI.

The SkyPilot CLI only runs on Linux and macOS. On Windows, use it from WSL. For WSL to reach the server on `127.0.0.1:30050`, turn on [mirrored networking](https://learn.microsoft.com/windows/wsl/networking#mirrored-mode-networking) (`networkingMode=mirrored` under `[wsl2]` in `%UserProfile%\.wslconfig`), or run `deploy.sh` from inside WSL with Docker Desktop's WSL integration enabled.

```bash
pip install "skypilot-nightly[kubernetes]"
source .credentials
sky api login -e "http://${WEB_USERNAME}:${WEB_PASSWORD}@127.0.0.1:30050"
sky check kubernetes
sky launch --infra k8s --cpus 1 -- echo hello from skypilot
```

## Recipes

[recipes/](recipes/README.md) has ready-to-run tasks: hello world, CPU MNIST training, a managed job that recovers from pod failures using a PVC checkpoint, 2-node PyTorch DDP, a FastAPI model server, and a vLLM GPU server for when a GPU cluster is attached.

## Tear down

```bash
./infra/scripts/teardown.sh
```
