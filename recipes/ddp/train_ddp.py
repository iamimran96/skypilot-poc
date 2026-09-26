"""Minimal multi-node PyTorch DDP training on CPU (gloo backend).

Launched by torchrun on every node; each process trains a tiny regression
model on synthetic data, and DDP averages gradients across nodes.
"""
import os

import torch
import torch.distributed as dist
import torch.nn as nn
from torch.nn.parallel import DistributedDataParallel as DDP


def main():
    dist.init_process_group(backend="gloo")
    rank, world = dist.get_rank(), dist.get_world_size()
    print(f"[rank {rank}/{world}] host={os.uname().nodename}", flush=True)

    torch.manual_seed(rank)
    true_w = torch.tensor([[2.0], [-3.0], [0.5]])
    model = DDP(nn.Linear(3, 1))
    opt = torch.optim.SGD(model.parameters(), lr=0.05)

    for step in range(200):
        x = torch.randn(64, 3)
        y = x @ true_w + 1.0 + 0.01 * torch.randn(64, 1)
        loss = nn.functional.mse_loss(model(x), y)
        opt.zero_grad()
        loss.backward()
        opt.step()
        if step % 50 == 0 and rank == 0:
            print(f"step {step} loss {loss.item():.5f}", flush=True)

    # Every rank ends up with identical weights because DDP syncs gradients.
    if rank == 0:
        w = model.module.weight.data.flatten().tolist()
        print(f"learned weights {[round(v, 3) for v in w]} (target [2.0, -3.0, 0.5])")
    dist.destroy_process_group()


if __name__ == "__main__":
    main()
