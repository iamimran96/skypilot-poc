# SkyPilot recipes

Ready-to-run tasks for the kind-hosted API server. Everything except `llm-serve-gpu` runs on CPU and fits on a laptop cluster.

Run them from a Linux shell (WSL on Windows) after connecting the CLI (see the main [README](../README.md#use-it)). Recipes that use `workdir: .` must be launched from their own folder so their code gets synced.

| Recipe | What it shows | Run |
|---|---|---|
| [hello](hello/task.yaml) | Provisioning a pod, `setup`/`run`, SkyPilot env vars | `sky launch -c hello recipes/hello/task.yaml` |
| [mnist](mnist/task.yaml) | Syncing code with `workdir`, installing deps, CPU training | `cd recipes/mnist && sky launch -c mnist task.yaml` |
| [mnist managed job](mnist/managed-job.yaml) | `sky jobs` with auto-recovery and checkpoints on a PVC volume | see below |
| [ddp](ddp/task.yaml) | Multi-node training (`num_nodes: 2`) with `torchrun` | `cd recipes/ddp && sky launch -c ddp task.yaml` |
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

The API server only allows the Kubernetes cloud (`allowed_clouds` in [infra/helm/values-kind.yaml](../infra/helm/values-kind.yaml)), and kind has no GPUs. To run `llm-serve-gpu`, add a GPU Kubernetes context or cloud credentials to the API server and update its config from the dashboard (the Helm `config` value only applies on first install).
