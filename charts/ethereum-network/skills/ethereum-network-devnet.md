---
name: ethereum-network-devnet
description: Bootstrap a brand-new Ethereum devnet from scratch on a Kubernetes cluster. Use when user says "起一个本地 devnet", "create a devnet", "spin up a private eth network", "bootstrap a test network", "ethpandaops genesis", or asks for an in-cluster Ethereum testbed where they control validators.
---

Trigger: user wants a fresh, isolated Ethereum network they fully own.

## Steps

1. Decide topology — N validator + M rpc nodes. For laptop k3d, start with `examples/devnet-minimal.yaml` (1 validator + 1 rpc). For multi-client experiments, copy `examples/devnet-full.yaml`.

2. Confirm a Kubernetes context exists (`k3d cluster list`; if none, `k3d cluster create -c lib/k3d-local0.conf`).

3. Install:
   ```bash
   helm install dev1 ./charts/charts/ethereum-network \
     -f charts/charts/ethereum-network/examples/devnet-minimal.yaml \
     -n eth --create-namespace
   ```

4. Wait for genesis sts to become ready (`kubectl wait pod/dev1-genesis-0 -n eth --for=condition=Ready --timeout=180s`).

5. Validator pod gets 3 containers: `el + cl + vc`. Block production starts ~`devnet.genesisGenerator.genesisDelay` seconds after install. Watch:
   ```bash
   kubectl exec dev1-genesis-0 -n eth -c nginx -- \
     curl -s http://dev1-validator1:5052/eth/v1/node/syncing
   ```

6. Optional peripherals — set in values:
   - `dora.enabled: true` — beacon-chain explorer at `dev1-dora-http-<suffix>.<baseDomain>`
   - `blockscout.enabled: true` — EVM explorer (also enables postgres)
   - `spamoor.enabled: true` — continuous tx generator

## Key values knobs

- `devnet.chainId` (default 32382)
- `devnet.validatorCount` — must match sum of `nodes[*].validatorKeys.indexEnd - indexStart`
- `devnet.preset` — `minimal` (fast slots) | `mainnet` (12s slot, 32 slots/epoch)
- `devnet.genesisGenerator.mnemonic` — controls all derived keys; keep test value in dev

## Why this chart

- ethpandaops/ethereum-genesis-generator produces `genesis.json` + `genesis.ssz` + per-node vc keystores in one init pass.
- Every node deterministically derives its EL nodekey & CL libp2p key from the shared mnemonic via `derive-p2p-key` init.
- A `peer-table` Job publishes a ConfigMap with everyone's enode/multiaddr so nodes can be pre-wired before any pod starts.
- One node is the **CL leader**; followers fetch its live ENR via `cl-peer-discovery` init container to break the discovery chicken-and-egg.
