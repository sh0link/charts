---
name: ethereum-network-join-custom
description: Attach additional nodes to an existing in-cluster devnet that someone else (or you, earlier) bootstrapped via mode=devnet. Use when user says "加入已经存在的 devnet", "follower node for our team's devnet", "scale out an existing private chain", "add an rpc to the dev1 release", "我有 genesis URL 想加节点".
---

Trigger: user wants nodes that follow an in-cluster custom devnet (not public, not new).

## Steps

1. Identify the source release's genesis service. Typically:
   ```bash
   kubectl get svc -A | grep genesis
   # e.g. eth   dev1-genesis  ClusterIP  10.43.91.183  80/TCP
   ```
   The genesis URL is `http://dev1-genesis.eth.svc.cluster.local`.

2. Find dev1's mnemonic + indexStart to enable deterministic peering:
   ```bash
   kubectl get secret dev1-mnemonic -n eth -o jsonpath='{.data.mnemonic}' | base64 -d
   kubectl get cm dev1-peer-table -n eth -o jsonpath='{.data.el-static-nodes\.txt}'
   ```
   The peer-table shows which HD indices are already used. Pick `join.custom.indexStart` ≥ (source_indexStart + 2*len(source_nodes)).

3. Edit `examples/join-custom-devnet.yaml`:
   - `join.custom.genesisUrl` → the source genesis service URL
   - `join.custom.mnemonic` → the source mnemonic (lets your nodes auto-discover others)
   - `join.custom.indexStart` → non-overlapping start

4. Install:
   ```bash
   helm install follower1 ./charts/charts/ethereum-network \
     -f charts/charts/ethereum-network/examples/join-custom-devnet.yaml \
     -n eth
   ```

5. Verify EL sync starts:
   ```bash
   kubectl exec dev1-genesis-0 -n eth -c nginx -- \
     curl -s http://follower1-follower-rpc1:8545 \
     -X POST -H content-type:application/json \
     --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
   ```

## Limitations

- The peer-table Job only computes enodes for **this release's** nodes. To connect to dev1 nodes, set `join.custom.bootnodes.el/cl` manually using the dev1 peer-table values.
- Future enhancement: extend the Job to consume `join.custom.sourceNodes` and produce cross-release peer table.

## Common pitfalls

- **HD index collision** → same enode/peer_id as a dev1 node → both nodes lose identity. Always check dev1's `p2pKey.indexStart` first.
- **Wrong mnemonic** → derive-p2p-key produces unrelated keys; nodes start fine but discovery never converges with dev1.
- **stale genesis** → if dev1 was reinstalled, its `genesis_validators_root` changed; follower with wrong root rejected by dev1 CL gossipsub. Reinstall follower.
