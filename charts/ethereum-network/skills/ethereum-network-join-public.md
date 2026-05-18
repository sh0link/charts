---
name: ethereum-network-join-public
description: Attach RPC / archive nodes to a public Ethereum network (mainnet, sepolia, holesky, hoodi). Use when user says "join mainnet", "加入 sepolia", "spin up an archive node", "我需要一个 mainnet rpc", "checkpoint sync", or wants nodes that follow an existing public chain (not bootstrap a new one).
---

Trigger: user wants nodes that follow a real public Ethereum network.

## Steps

1. Pick the network:
   - mainnet → `examples/join-public-mainnet.yaml` (1 archive geth+lighthouse)
   - sepolia → `examples/join-public-sepolia.yaml` (2 heterogeneous RPC nodes)

2. Install:
   ```bash
   helm install sepolia ./charts/charts/ethereum-network \
     -f charts/charts/ethereum-network/examples/join-public-sepolia.yaml \
     -n eth --create-namespace
   ```

3. Verify checkpoint sync starts:
   ```bash
   kubectl logs sepolia-rpc1-0 -n eth -c cl --tail=20
   # expect: "Loaded checkpoint sync state" then peer counts climbing
   ```

4. Expected reach EL sync within ~hours for mainnet (depending on snapshot), ~10 min for sepolia.

## What the chart does NOT do in join.public

- No mnemonic Secret (no shared keys)
- No deterministic peer table (public DHT does discovery)
- No genesis service (EL/CL ship genesis built-in for known networks)
- No validator client (these are observation nodes, not validators)

## Key values knobs

- `join.public.network` — mainnet | sepolia | holesky | hoodi
- `join.public.checkpointSyncUrl` — override default per-network table
- `nodes[*].el.persistence.size` — mainnet archive needs ≥ 1800Gi as of 2026
- Add a single rpc node by appending to `nodes:`, then `helm upgrade`

## Why use this chart over a hand-rolled sts

- Headless service per node with stable pod DNS for enode stability across restarts.
- VMServiceScrape auto-rendered when the VictoriaMetrics CRD is installed.
- Domain suffix per node ensures `mainnet-rpc1` and `sepolia-rpc1` ingress hosts never collide on a shared cluster.
