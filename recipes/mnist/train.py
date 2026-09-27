"""Train a small CNN on MNIST (CPU or GPU) with optional checkpoint/resume.

When --ckpt-dir is set, a checkpoint is written after every epoch and training
resumes from it on restart, which is what lets a SkyPilot managed job recover
after its pod is preempted or deleted.
"""
import argparse
import os

import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import DataLoader
from torchvision import datasets, transforms


class Net(nn.Module):
    def __init__(self):
        super().__init__()
        self.conv1 = nn.Conv2d(1, 16, 3, 1)
        self.conv2 = nn.Conv2d(16, 32, 3, 1)
        self.fc1 = nn.Linear(32 * 12 * 12, 64)
        self.fc2 = nn.Linear(64, 10)

    def forward(self, x):
        x = F.relu(self.conv1(x))
        x = F.max_pool2d(F.relu(self.conv2(x)), 2)
        x = torch.flatten(x, 1)
        x = F.relu(self.fc1(x))
        return self.fc2(x)


def evaluate(model, loader, device):
    model.eval()
    correct = 0
    with torch.no_grad():
        for x, y in loader:
            x, y = x.to(device), y.to(device)
            correct += (model(x).argmax(1) == y).sum().item()
    return correct / len(loader.dataset)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--epochs", type=int, default=2)
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--lr", type=float, default=1e-3)
    parser.add_argument("--data-dir", default="./data")
    parser.add_argument("--ckpt-dir", default=None)
    args = parser.parse_args()

    torch.manual_seed(0)
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    print(f"Using device: {device}" + (f" ({torch.cuda.get_device_name(0)})" if device.type == "cuda" else ""))
    tfm = transforms.Compose([transforms.ToTensor(), transforms.Normalize((0.1307,), (0.3081,))])
    train_ds = datasets.MNIST(args.data_dir, train=True, download=True, transform=tfm)
    test_ds = datasets.MNIST(args.data_dir, train=False, download=True, transform=tfm)
    train_dl = DataLoader(train_ds, batch_size=args.batch_size, shuffle=True)
    test_dl = DataLoader(test_ds, batch_size=512)

    model = Net().to(device)
    opt = torch.optim.Adam(model.parameters(), lr=args.lr)
    start_epoch = 0

    ckpt_path = None
    if args.ckpt_dir:
        os.makedirs(args.ckpt_dir, exist_ok=True)
        ckpt_path = os.path.join(args.ckpt_dir, "checkpoint.pt")
        if os.path.exists(ckpt_path):
            state = torch.load(ckpt_path, map_location=device)
            model.load_state_dict(state["model"])
            opt.load_state_dict(state["opt"])
            start_epoch = state["epoch"] + 1
            print(f"Resumed from {ckpt_path} at epoch {start_epoch}")

    for epoch in range(start_epoch, args.epochs):
        model.train()
        for step, (x, y) in enumerate(train_dl):
            x, y = x.to(device), y.to(device)
            opt.zero_grad()
            loss = F.cross_entropy(model(x), y)
            loss.backward()
            opt.step()
            if step % 100 == 0:
                print(f"epoch {epoch} step {step}/{len(train_dl)} loss {loss.item():.4f}", flush=True)
        acc = evaluate(model, test_dl, device)
        print(f"epoch {epoch} test accuracy {acc:.4f}", flush=True)
        if ckpt_path:
            torch.save({"model": model.state_dict(), "opt": opt.state_dict(), "epoch": epoch}, ckpt_path)
            print(f"Saved checkpoint to {ckpt_path}")

    print("Training complete")


if __name__ == "__main__":
    main()
