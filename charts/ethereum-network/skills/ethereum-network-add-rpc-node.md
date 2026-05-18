---
name: ethereum-network-add-rpc-node
description: Add a new RPC (non-validator) node to an existing ethereum-network release. Use when user says "give me another rpc", "scale out rpc", "再加一个 rpc 节点", "我需要一个archive节点", "add a reth node to the dev1 devnet".
---

Trigger: a release is already running and the user wants more read-only / observation nodes without changing the validator set.

## Steps

1. Locate the active values file for the release. By convention `examples/<mode>.yaml`. Inspect current `nodes` list:
   ```bash
   helm get values dev1 -n eth | yq .nodes
   ```

2. Append a new entry to `nodes:` (same yaml structure as existing rpc1). Use a fresh `name`:
   ```yaml
   - name: rpc2
     role: rpc          # NOT validator — no vc, no validatorKeys
     el:
       client: reth     # any supported client
       image: { repository: ghcr.io/paradigmxyz/reth, tag: v1.11.3 }
       dataPath: /data/ethereum
       commandShell: true
       command:
         - |
           exec reth node \
             --chain=/shared/el-genesis.json \
             --datadir=/data/ethereum \
             ...
       persistence: { size: 20Gi }
       ports: [ {name: rpc, port: 8545}, {name: ws, port: 8546}, {name: authrpc, port: 8551}, {name: p2p, port: 30303}, {name: metric, port: 6061} ]
     cl:
       client: lighthouse
       ...
   ```

3. `helm upgrade dev1` with the modified values. The chart will:
   - Add the new sts/svc/ingress
   - Re-run `derive-peer-table` Job → ConfigMap gains the new node's enode/multiaddr
   - Existing pods read the updated ConfigMap on their next restart (or via kubelet projected volume sync)

4. Force existing pods to pick up the new peer table:
   ```bash
   kubectl rollout restart sts dev1-validator1 dev1-rpc1 -n eth
   ```
   Skip this if the existing nodes will discover the new node via gossipsub eventually anyway.

## Why this works seamlessly

- HD index for the new node is auto-computed by ordinal in the nodes array — no manual index bookkeeping.
- Headless service per node gives stable enode DNS regardless of other nodes coming and going.
- The new node's `cl-peer-discovery` init container fetches the CL leader's live ENR for boot-nodes.

## Pitfalls

- Don't re-order existing nodes in the array — that changes their HD indices → fresh enode + new peer ID, breaking running peers.
- Always append to the **end** of `nodes:`.
