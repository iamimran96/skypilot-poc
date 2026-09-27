# SkyPilot recipes

Ready-to-run tasks for the kind-hosted API server. Everything except `llm-serve-gpu` runs on CPU and fits on a laptop cluster. [mnist/train.py](mnist/train.py) also uses a GPU when the task has one.

Run them from a Linux shell (WSL on Windows) after connecting the CLI (see the main [README](../README.md#use-it)). Recipes that use `workdir: .` must be launched from their own folder so their code gets synced, or with `--workdir recipes/<name>` from the project root. Give `sky launch` a task path that exists from your current directory, otherwise SkyPilot runs it as a shell command (`task.yaml: command not found`).

| Recipe | What it shows | Run |
|---|---|---|
| [hello](hello/task.yaml) | Provisioning a pod, `setup`/`run`, SkyPilot env vars | `sky launch -c hello recipes/hello/task.yaml` |
| [mnist](mnist/task.yaml) | Syncing code with `workdir`, installing deps, CPU training | `cd recipes/mnist && sky launch -c mnist task.yaml` |
| [mnist managed job](mnist/managed-job.yaml) | `sky jobs` with auto-recovery and checkpoints on a PVC volume | see below |
| [ddp](ddp/task.yaml) | Multi-node training (`num_nodes: 2`) with `torchrun` on CPU | `cd recipes/ddp && sky launch -c ddp task.yaml`, or as a managed job: `sky jobs launch -n ddp recipes/ddp/task.yaml --workdir recipes/ddp` |
| [serve](serve/task.yaml) | Long-running FastAPI model server with an exposed port | `cd recipes/serve && sky launch -c serve task.yaml` |
| [llm-serve-gpu](llm-serve-gpu/task.yaml) | vLLM OpenAI-compatible server (needs a GPU cluster or cloud) | `sky launch -c llm recipes/llm-serve-gpu/task.yaml` |

## Managed job with recovery

```bash
sky volumes apply recipes/mnist/volume.yaml
cd recipes/mnist
sky jobs launch -n mnist-job managed-job.yaml
sky jobs queue
```

While it trains, delete its pod (`kubectl --context kind-skypilot -n skypilot get pods`, then `kubectl ... delete pod <name>`). SkyPilot relaunches the job, and `train.py` resumes from the last checkpoint in `/ckpt`. `sky jobs logs <id>` shows the `Resumed from ...` line.

## Everyday commands

```bash
sky status                 # clusters and their state
sky logs <cluster>         # stream the latest job's logs
sky exec <cluster> task.yaml   # rerun on an existing cluster, skipping setup
sky down <cluster>         # delete the cluster's pods
sky down -a                # delete all clusters
```

## GPU recipe

A cluster created with `GPU=1 ./infra/scripts/deploy.sh` exposes the local NVIDIA GPU (see the main [README](../README.md#gpu-cluster-optional)). Run GPU work on it with, for example:

```bash
sky launch -c gpu-test --gpus rtx5060:1 recipes/mnist/task.yaml --workdir recipes/mnist
```

`llm-serve-gpu` still requests `{L4, A10G, A100}` and says kind has no GPUs, so it will not schedule on the local GPU until its `accelerators` and vLLM settings are changed to fit the card. On the CPU-only cluster, or to use real cloud GPUs, add a GPU Kubernetes context or cloud credentials to the API server and update its config from the dashboard (the Helm `config` value only applies on first install). The API server only allows the Kubernetes cloud (`allowed_clouds` in [infra/helm/values-kind.yaml](../infra/helm/values-kind.yaml)).
