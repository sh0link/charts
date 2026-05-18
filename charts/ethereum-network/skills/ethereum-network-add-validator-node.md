---
name: ethereum-network-add-validator-node
description: Add a new validator node to an existing ethereum-network devnet. Use when user says "add another validator", "加一个验证者节点", "扩大 active validator set", "add a teku validator". REQUIRES recreating genesis because the validator set is baked into genesis.ssz — this is destructive to chain state.
---

Trigger: user wants to grow the active validator set on an in-cluster devnet.

## Warning

**Adding a validator requires re-generating genesis** because the validator stake is part of the genesis state. The chain history is wiped. If this is unacceptable, use `ethereum-network-add-rpc-node` instead (read-only RPC adds no validator obligations).

## Steps

1. Decide HD index slice for the new validator. Pick a non-overlapping range past existing validators:
   ```bash
   helm get values dev1 -n eth | yq '.nodes[] | select(.role=="validator") | .validatorKeys'
   ```
   e.g. existing v1=[0,64), v2=[64,128); new v3 takes [128,192).

2. Bump `devnet.validatorCount` to include the new range's max. Example: from 128 to 192.

3. Append the new validator to `nodes:`:
   ```yaml
   - name: validator3
     role: validator
     validatorKeys: { indexStart: 128, indexEnd: 192 }
     el: { client: geth, ... }
     cl: { client: teku, ... }   # any supported CL
   ```

4. Uninstall + delete PVCs + reinstall (genesis must regenerate):
   ```bash
   helm uninstall dev1 -n eth
   kubectl delete pvc --all -n eth --wait=true
   helm install dev1 ./charts/charts/ethereum-network -f path/to/values.yaml -n eth
   ```

5. Wait ~`devnet.genesisGenerator.genesisDelay` seconds + image-pull time, then verify all 3 validators show `voting_validators: <N>` in their vc logs:
   ```bash
   kubectl logs dev1-validator3-0 -n eth -c vc | grep voting_validators
   ```

## Why not in-place

ethereum-genesis-generator writes the full validator BLS keyset and stake values into `genesis.ssz`. Validators added post-genesis would need to deposit via the deposit contract and wait for activation queue — far more involved than the chart targets. For that workflow, use the spamoor + a deposit scenario, or write a custom Job that calls the deposit contract.

## Pitfalls

- **HD index gap or overlap** → ethpandaops generator silently uses contiguous indices; gaps mean fewer validators than declared. Always make ranges contiguous, no overlap.
- **`devnet.validatorCount` < sum of node ranges** → genesis only contains the first N validators; the late ones have no stake and vc complains `No enabled validators`.
- **Different CL clients per validator** → fine, but their derived libp2p key file format differs — chart's `derive-p2p-key` already handles per-client serialization.
