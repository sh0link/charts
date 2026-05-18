# ethereum-network — Design

> Helm chart for deploying Ethereum networks. Two top-level modes:
> - **devnet** — bootstrap a brand-new network from scratch using
>   `ethpandaops/ethereum-genesis-generator`.
> - **join** — attach nodes to an existing network. Two sub-sources:
>   - `public` — mainnet/sepolia/holesky/hoodi (EL/CL built-in genesis).
>   - `custom` — any devnet by fetching its genesis service.

Independent of `charts/charts/ethereum-node` — no shared templates. The two
charts will be kept in sync at the values-schema level (`el.*`, `cl.*`) but
the network chart owns multi-node orchestration, genesis generation, and
deterministic P2P wiring.

---

## 1. Modes & data flow

```
┌───────────────────┐
│   mode: devnet    │  generate genesis → serve via nginx → all nodes fetch
└───────────────────┘
        │
        ├── statefulset-genesis (1 pod)
        │     init: ethereum-genesis-generator → /data
        │     init: copy to /usr/share/nginx/html
        │     main: nginx serves :80
        │
        ├── statefulset-<nodeN> × len(nodes)
        │     init: wait-for-genesis (curl genesis svc /ready)
        │     init: fetch-genesis (el-genesis.json, cl-config/*)
        │     init: derive-p2p-key (HD index 100+)
        │     init: el-init (geth init / reth init-genesis)
        │     init: gen-jwt
        │     main: EL sidecar + CL sidecar
        │
        ├── job-derive-peer-table (helm hook pre-install/pre-upgrade)
        │     out: ConfigMap with el-static-nodes.txt + cl-trusted-peers.txt
        │
        └── (optional) postgres / dora / blockscout / spamoor


┌───────────────────────────┐
│ mode: join.source=public  │  --network=<name> + checkpoint URL
└───────────────────────────┘
        │
        └── statefulset-<nodeN>
              init: derive-p2p-key (optional, default off for public)
              init: gen-jwt
              main: EL (--mainnet/--sepolia/...) + CL (--network=<name>)
        # no genesis service, no peer-table Job


┌────────────────────────────┐
│ mode: join.source=custom   │  fetch remote devnet's genesis
└────────────────────────────┘
        │
        └── statefulset-<nodeN>
              init: wait-for-genesis (against join.custom.genesisUrl)
              init: fetch-genesis
              init: derive-p2p-key (if mnemonic provided)
              init: el-init
              init: gen-jwt
              main: EL + CL
        # peer-table Job optional: needs source devnet's mnemonic + index
```

---

## 2. Repo layout

```
charts/charts/ethereum-network/
├── Chart.yaml
├── DESIGN.md                         (this file)
├── REQ.md                            (original requirements)
├── values.yaml                       defaults + inline docs
├── values.schema.json                optional, post-MVP
├── templates/
│   ├── _helpers.tpl                  mode flags, name, domainSuffix, mnemonic
│   ├── _node-statefulset.tpl         define: per-node statefulset block
│   ├── NOTES.txt
│   │
│   ├── secret-mnemonic.yaml          devnet + join.custom: shared mnemonic
│   ├── rbac-peer-table.yaml          SA + Role for the derive-peer-table Job
│   ├── configmap-derive-script.yaml  derive.py mounted into the Job
│   ├── job-derive-peer-table.yaml    Helm hook pre-install/pre-upgrade
│   │
│   ├── configmap-genesis-nginx.yaml  nginx site config for /ready, etc.
│   ├── statefulset-genesis.yaml      devnet only
│   ├── service-genesis.yaml          devnet only (ClusterIP)
│   │
│   ├── statefulset-nodes.yaml        range .Values.nodes → N statefulsets
│   ├── service-nodes.yaml            range → N headless services (DNS stability)
│   │
│   ├── statefulset-postgres.yaml     gated by needsPostgres
│   ├── statefulset-dora.yaml         gated by .Values.dora.enabled
│   ├── configmap-dora.yaml
│   ├── statefulset-blockscout.yaml   gated by .Values.blockscout.enabled
│   ├── statefulset-spamoor.yaml      gated by .Values.spamoor.enabled
│   │
│   ├── ingress.yaml                  one file, conditional sections per mode
│   └── vmservicescrape.yaml          guarded by Capabilities + values flag
│
├── examples/
│   ├── devnet-minimal.yaml           1 validator + 1 rpc
│   ├── devnet-full.yaml              4 v + 2 rpc + dora + blockscout + spamoor
│   ├── join-public-mainnet.yaml      mainnet archive RPC
│   ├── join-public-sepolia.yaml      sepolia 2 RPC heterogeneous EL/CL
│   └── join-custom-devnet.yaml       attach to an existing devnet
│
└── helmreleases/                     Flux HelmRelease wrappers
    ├── devnet-full.yaml
    ├── join-public-sepolia.yaml
    └── join-custom-devnet.yaml
```

---

## 3. Top-level values shape

```yaml
mode: devnet                          # devnet | join

nameOverride: ""
fullnameOverride: ""
baseDomain: example.org
domainSuffixEnabled: true             # sha256→trunc8→repeat3→b64enc→trunc8→lower
storageClass: ""

ingress:
  enabled: true
  className: traefik
  annotations: {}
  tls: []

# Shared mnemonic (devnet + join.custom). Empty when join.public.
# Helper "ethereum-network.effectiveMnemonic" resolves precedence:
#   devnet.genesisGenerator.mnemonic > join.custom.mnemonic > .Values.mnemonic
mnemonic: ""

# ─── P2P key derivation (deterministic) ────────────────────────────────────
p2pKey:
  enabled: true                       # false → openssl rand per node (old behaviour)
  hdPathPrefix: "m/44'/60'/0'/0"
  indexStart: 100                     # node i: el=indexStart+i*2, cl=indexStart+i*2+1

# ─── Peer-table Job ────────────────────────────────────────────────────────
peerTable:
  enabled: true                       # gated to devnet + (join.custom with mnemonic)
  image: ghcr.io/sh0link/debugger:1.0.0

# ─── Mode: devnet ──────────────────────────────────────────────────────────
devnet:
  chainId: 32382
  preset: minimal                     # minimal | mainnet
  genesisGenerator:
    image: ethpandaops/ethereum-genesis-generator:4.0.0
    elFork: cancun
    clFork: deneb
    genesisDelay: 30
    genesisTimestamp: ""              # empty = now + delay
    mnemonic: "test test test test test test test test test test test alone"
  validatorCount: 64
  genesisService:
    image: ghcr.io/sh0link/debugger:1.0.0
    port: 80
    persistence: { size: 1Gi }

# ─── Mode: join ────────────────────────────────────────────────────────────
join:
  source: public                      # public | custom
  public:
    network: mainnet                  # mainnet | sepolia | holesky | hoodi
    checkpointSyncUrl: ""             # empty = built-in default table
  custom:
    genesisUrl: ""                    # e.g. http://other-rel-genesis.eth.svc
    mnemonic: ""                      # if provided, enables peerTable for self-discovery
    indexStart: 100                   # source devnet's p2pKey.indexStart
    bootnodes:
      el: []
      cl: []
    checkpointSyncUrl: ""
    chainId: 0

# ─── Node topology ─────────────────────────────────────────────────────────
nodes:
  - name: validator1
    role: validator                   # validator | rpc
    replicas: 1
    p2pKey:
      elIndexOverride: ~              # default = computed by ordinal
      clIndexOverride: ~
    el:
      client: geth                    # geth | reth | erigon | nethermind | besu
      image: ethereum/client-go:v1.16.9
      dataPath: /data/ethereum
      commandShell: false
      command: [...]
      resources: {}
      persistence: { size: 100Gi, storageClassName: "" }
      ports:                          # default common set; override per node
        - { name: rpc, port: 8545 }
        - { name: ws, port: 8546 }
        - { name: authrpc, port: 8551 }
        - { name: p2p, port: 30303 }
        - { name: metric, port: 6061 }
    cl:
      client: lighthouse              # lighthouse | prysm | teku | nimbus
      image: sigp/lighthouse:v8.1.1
      dataPath: /data/lighthouse
      command: [...]
      resources: {}
      persistence: { size: 50Gi, storageClassName: "" }
      ports:
        - { name: beacon, port: 5052 }
        - { name: p2p, port: 9000 }
        - { name: metric, port: 5054 }
    # validator-only: range of HD indices for validator signing keys
    validatorKeys:
      indexStart: 0
      indexEnd: 64

  - name: rpc1
    role: rpc
    el: { client: reth, ... }
    cl: { client: prysm, ... }

# ─── Peripheral services ───────────────────────────────────────────────────
postgres:
  enabled: false                      # auto-on if dora or blockscout enabled
  image: postgres:16
  persistence: { size: 20Gi }

dora:
  enabled: false
  image: ethpandaops/dora:latest
  # auto-config: every node's CL beacon URL is pushed into the dora ConfigMap

blockscout:
  enabled: false
  image: blockscout/blockscout:latest

spamoor:
  enabled: false
  image: ethpandaops/spamoor:latest
  scenarios: [eoatx]

vmServiceScrape:
  enabled: true                       # AND .Capabilities check
```

---

## 4. Helpers (`_helpers.tpl`)

| Helper | Returns |
|---|---|
| `ethereum-network.name` | chart name |
| `ethereum-network.fullname` | release name |
| `ethereum-network.labels` | std labels |
| `ethereum-network.isDevnet` | "true" when `mode == "devnet"` |
| `ethereum-network.isJoin` | "true" when `mode == "join"` |
| `ethereum-network.isJoinPublic` | "true" when join + public |
| `ethereum-network.isJoinCustom` | "true" when join + custom |
| `ethereum-network.needsGenesis` | "true" when devnet — triggers genesis sts |
| `ethereum-network.needsPostgres` | "true" if dora.enabled OR blockscout.enabled OR postgres.enabled |
| `ethereum-network.vmScrapeEnabled` | `vmServiceScrape.enabled` AND `Capabilities.APIVersions.Has "operator.victoriametrics.com/v1beta1/VMServiceScrape"` |
| `ethereum-network.peerTableEnabled` | `peerTable.enabled` AND (devnet OR (join.custom AND mnemonic set)) |
| `ethereum-network.effectiveMnemonic` | resolves per-mode mnemonic source |
| `ethereum-network.genesisUrl` | devnet: `http://{release}-genesis`; join.custom: `.Values.join.custom.genesisUrl`; join.public: empty |
| `ethereum-network.defaultCheckpointUrl` | network name → built-in URL |
| `ethereum-network.effectiveCheckpointUrl` | values override vs default |
| `ethereum-network.elKeyIndex` | `(dict "ordinal" i "ctx" $) → indexStart + i*2` |
| `ethereum-network.clKeyIndex` | `(dict "ordinal" i "ctx" $) → indexStart + i*2 + 1` |
| `ethereum-network.domainSuffix` | sha256 → trunc 8 → repeat 3 → b64enc → trunc 8 → lower |
| `ethereum-network.host` | `{release}-{svc}-{port}-{suffix}.{baseDomain}` |
| `ethereum-network.nodeName` | `{release}-{node.name}` |
| `ethereum-network.nodeFQDN` | `{release}-{node.name}.{namespace}.svc.cluster.local` |
| `ethereum-network.nodeStatefulSet` | (define) full sts body, called from range |

---

## 5. Init chains

### 5.1 Genesis pod (devnet only)

```
init-1: generate-genesis
  image: ethpandaops/ethereum-genesis-generator
  env:
    EL_GENESIS_TIMESTAMP
    EL_AND_CL_MNEMONIC
    NUMBER_OF_VALIDATOR_KEYS
    PRESET_BASE
  mounts: /data (PVC)
  skip if /data/.genesis-generated exists
init-2: prepare-static-files
  image: debugger
  cp -r /data/* /web/
  echo "ok" > /web/ready
main:   nginx, /web → /usr/share/nginx/html
```

### 5.2 Node pod — devnet OR join.custom

```
init-1: wait-for-genesis
  curl --retry 30 --retry-delay 2 {genesisUrl}/ready
init-2: fetch-genesis
  wget {genesisUrl}/el/genesis.json → /shared/el-genesis.json
  wget {genesisUrl}/cl/config.yaml  → /shared/cl-config/config.yaml
  wget {genesisUrl}/cl/genesis.ssz  → /shared/cl-config/genesis.ssz
  wget {genesisUrl}/cl/deposit_contract_block.txt → ...
  (validator role only)
  wget {genesisUrl}/validators/keys.tar  → /shared/validator-keys.tar
init-3: derive-p2p-key
  cast wallet derive-private-key $MNEMONIC $EL_INDEX → /el-data/nodekey
  cast wallet derive-private-key $MNEMONIC $CL_INDEX → /cl-data/p2p-secret
  skip if files exist
init-4: el-init  (only if not already initialized)
  case $EL_CLIENT in
    geth)   geth init --datadir $DATA /shared/el-genesis.json ;;
    reth)   reth init --datadir $DATA --chain /shared/el-genesis.json ;;
    erigon) erigon init --datadir $DATA /shared/el-genesis.json ;;
  esac
  touch /el-data/.initialized
init-5: gen-jwt
  test -f /jwt/jwtsecret || head -c 32 /dev/urandom | xxd -p -c 32 > /jwt/jwtsecret
init-6: wait-for-peer-table       (only if peerTableEnabled)
  until kubectl get cm $REL-peer-table; do sleep 2; done
  cp /peers/el-static-nodes.txt → $DATA/geth/static-nodes.json (geth) or
                                  → flag --trusted-peers (reth)
main:
  el: $EL_COMMAND
  cl: $CL_COMMAND --execution-endpoint=http://localhost:8551
```

### 5.3 Node pod — join.public

```
init-1: derive-p2p-key   (only if p2pKey.enabled)
init-2: gen-jwt
main:
  el: geth --mainnet ... --authrpc.jwtsecret=/jwt/jwtsecret
  cl: lighthouse beacon_node --network=mainnet \
        --checkpoint-sync-url={effectiveCheckpointUrl} \
        --execution-endpoint=http://localhost:8551 \
        --execution-jwt=/jwt/jwtsecret
```

---

## 6. Peer-table Job

`templates/job-derive-peer-table.yaml`:

```yaml
metadata:
  annotations:
    helm.sh/hook: pre-install,pre-upgrade
    helm.sh/hook-weight: "-10"
    helm.sh/hook-delete-policy: before-hook-creation
spec:
  template:
    spec:
      serviceAccountName: {release}-peer-table
      restartPolicy: OnFailure
      containers:
        - name: derive
          image: peerTable.image
          env:
            MNEMONIC (from Secret)
            INDEX_START
            NODES_JSON  (toJson .Values.nodes)
            NAMESPACE / RELEASE
          volumeMounts:
            - script (ConfigMap with derive.py)
          command:
            python3 /scripts/derive.py
              # outputs:
              #   /tmp/el-static-nodes.txt
              #   /tmp/cl-trusted-peers.txt
            kubectl create cm $REL-peer-table \
              --from-file=el-static-nodes.txt=/tmp/... \
              --from-file=cl-trusted-peers.txt=/tmp/... \
              --dry-run=client -o yaml | kubectl apply -f -
```

**`derive.py` outputs**:
- `el-static-nodes.txt` — one enode URL per line:
  `enode://{pubkey_hex}@{release}-{node.name}.{ns}.svc.cluster.local:30303`
- `cl-trusted-peers.txt` — one multiaddr per line:
  `/dns4/{release}-{node.name}.{ns}/tcp/9000/p2p/{peer_id}`

**Per EL client wiring**:
- geth: `static-nodes.json` placed at `$DATADIR/geth/static-nodes.json`
- reth: `--trusted-peers <comma list>`
- erigon: `--staticpeers <comma list>`
- nethermind: `StaticNodes.json` at `$DATADIR/Nethermind/StaticNodes.json`

**Per CL client wiring**:
- lighthouse: `--trusted-peers <comma list>` and `--libp2p-private-key-file=/cl-data/p2p-secret`
- prysm: `--peer=<multiaddr>` (repeatable) + `--p2p-priv-key=/cl-data/p2p-secret`
- teku: `--p2p-static-peers=<list>` + `--p2p-private-key-file=/cl-data/p2p-secret`

Per-client CL key file format compatibility lives in `derive.py` — P3 work.
MVP supports lighthouse only.

---

## 7. Ingress

One file, range over nodes plus mode-gated peripheral hosts.

Per node: 1 Ingress with multiple host rules — `rpc`, `ws`, `beacon`,
`metric` ports, each via `ethereum-network.host` helper.

Devnet adds: genesis service ingress.
Optional peripherals add: dora, blockscout, spamoor hosts.

Host format (matches ethereum-node):
```
{release}-{node.name}-{port}-{suffix}.{baseDomain}
```

`suffix` is computed from `sha256(release + node.name)`.

---

## 8. VMServiceScrape

```yaml
{{- if include "ethereum-network.vmScrapeEnabled" . }}
{{- $ctx := . }}
{{- range $i, $node := .Values.nodes }}
---
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: {{ $ctx.Release.Name }}-{{ $node.name }}
spec:
  endpoints:
    - { port: el-metric, path: /debug/metrics/prometheus }
    - { port: cl-metric, path: /metrics }
  selector:
    matchLabels:
      app: {{ $ctx.Release.Name }}-{{ $node.name }}
{{- end }}
{{- end }}
```

Capabilities check ensures clean rendering on clusters without VM operator.

---

## 9. Phases

| # | Scope | Validation |
|---|---|---|
| P0 | Chart.yaml + values.yaml + _helpers.tpl + NOTES.txt | `helm lint` |
| P1a | join.public: nodes sts + svc + ingress + vmscrape (no peer-table) | `helm install` sepolia RPC on k3d, see beacon sync |
| P2 | devnet genesis sts + svc + node init chain (genesis fetch path) | devnet-minimal 1v block production |
| P2.5 | mnemonic Secret + derive-p2p-key + derive-peer-table Job + headless svc | nodes show each other as trusted peer |
| P1b | join.custom path (reuse most of P2 init logic) | join existing devnet, sync from genesis |
| P3 | Heterogeneous EL/CL clients (reth/erigon, prysm/teku, nimbus) | devnet-full P2P mesh across clients |
| P4 | postgres + dora | dora UI shows all nodes |
| P5 | blockscout + spamoor + skills | end-to-end + skills |

---

## 10. Open risks

1. **CL peer-ID key format per client** — lighthouse/prysm/teku each
   expect different on-disk shapes. MVP: lighthouse only; P3 broadens.
2. **EL static-nodes / trusted-peers flag per client** — geth uses a JSON
   file, reth/erigon use CLI flags. Template branches per
   `node.el.client`.
3. **DNS-name stability** — relies on headless Service per node. Pods
   must use stateful pod-name DNS, not Service DNS, to keep enode URLs
   sticky across restarts.
4. **Helm hook failure mode** — if `derive-peer-table` Job fails on
   upgrade, pre-existing nodes keep using the old ConfigMap (acceptable);
   new nodes will block at `wait-for-peer-table` (fail-loud, fixable).
5. **Mnemonic security** — devnet only. Documented as "test only" in
   values.yaml. Production-grade devnets must override mnemonic.
