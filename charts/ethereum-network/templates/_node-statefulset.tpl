{{/*
ethereum-network.nodeStatefulSet — full StatefulSet body for one node.

Call signature:
  {{- include "ethereum-network.nodeStatefulSet" (dict "node" $node "ordinal" $i "ctx" $) }}

Behaviour matrix:

                       │ devnet │ join.public │ join.custom
  ─────────────────────┼────────┼─────────────┼────────────
  wait-for-genesis     │   ✓    │     ✗       │     ✓
  fetch-genesis        │   ✓    │     ✗       │     ✓
  derive-p2p-key       │   ✓    │   if enabled│   if enabled
  el-init              │   ✓    │     ✗       │     ✓
  gen-jwt              │   ✓    │     ✓       │     ✓
  wait-for-peer-table  │   ✓    │     ✗       │   if enabled
*/}}

{{- define "ethereum-network.nodeStatefulSet" -}}
{{- $node := .node -}}
{{- $i := .ordinal -}}
{{- $ctx := .ctx -}}
{{- $rel := $ctx.Release.Name -}}
{{- $ns := $ctx.Release.Namespace -}}
{{- $name := printf "%s-%s" $rel $node.name -}}
{{- $needsGenesisFetch := or (include "ethereum-network.isDevnet" $ctx) (include "ethereum-network.isJoinCustom" $ctx) -}}
{{- $genesisUrl := include "ethereum-network.genesisUrl" $ctx -}}
{{- $deriveP2p := and $ctx.Values.p2pKey.enabled (include "ethereum-network.effectiveMnemonic" $ctx) -}}
{{- $elIdx := include "ethereum-network.elKeyIndex" (dict "ordinal" $i "node" $node "ctx" $ctx) -}}
{{- $clIdx := include "ethereum-network.clKeyIndex" (dict "ordinal" $i "node" $node "ctx" $ctx) -}}
{{- $peerTable := include "ethereum-network.peerTableEnabled" $ctx -}}
{{- $vcOrdinal := include "ethereum-network.validatorOrdinal" (dict "node" $node "ctx" $ctx) -}}
{{- $isValidator := eq $node.role "validator" -}}
{{- $clLeaderName := include "ethereum-network.clLeaderName" $ctx -}}
{{- $isClLeader := include "ethereum-network.isClLeader" (dict "node" $node "ctx" $ctx) -}}
{{- $needsClBootstrap := and $needsGenesisFetch $clLeaderName (not $isClLeader) -}}
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: {{ $name }}
  labels:
    {{- include "ethereum-network.labels" $ctx | nindent 4 }}
    app: {{ $name }}
    ethereum-network.io/role: {{ $node.role }}
    ethereum-network.io/el: {{ $node.el.client }}
    ethereum-network.io/cl: {{ $node.cl.client }}
spec:
  replicas: {{ $node.replicas | default 1 }}
  serviceName: {{ $name }}
  selector:
    matchLabels:
      app: {{ $name }}
  template:
    metadata:
      labels:
        app: {{ $name }}
        ethereum-network.io/role: {{ $node.role }}
    spec:
      terminationGracePeriodSeconds: {{ $node.terminationGracePeriodSeconds | default 60 }}
      {{- with $node.nodeSelector }}
      nodeSelector: {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $node.tolerations }}
      tolerations: {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $node.affinity }}
      affinity: {{- toYaml . | nindent 8 }}
      {{- end }}
      volumes:
        - { name: jwt, emptyDir: {} }
        {{- if $needsGenesisFetch }}
        - { name: shared, emptyDir: {} }
        {{- end }}
        {{- if and $isValidator $vcOrdinal $needsGenesisFetch }}
        - { name: vc-data, emptyDir: {} }
        {{- end }}
        {{- if $deriveP2p }}
        - name: script
          configMap:
            name: {{ $rel }}-derive-script
        {{- end }}
        {{- if $peerTable }}
        # peers-cm: readonly ConfigMap mount (raw artefacts from the Job)
        # peers:    writable emptyDir where wait-and-apply-peer-table copies
        #           + derives CSV forms for client commands
        - name: peers-cm
          configMap:
            name: {{ $rel }}-peer-table
            optional: true
        - { name: peers, emptyDir: {} }
        {{- end }}

      initContainers:
        # ── 1. Wait for genesis service (devnet / join.custom) ─────────
        {{- if $needsGenesisFetch }}
        - name: wait-for-genesis
          image: {{ $ctx.Values.peerTable.image }}
          imagePullPolicy: IfNotPresent
          command: [/bin/sh, -c]
          args:
            - |
              set -e
              URL="{{ $genesisUrl }}/ready"
              echo "Waiting for genesis service: $URL"
              for i in $(seq 1 120); do
                if curl -fsS "$URL" >/dev/null 2>&1; then
                  echo "Genesis service ready"
                  exit 0
                fi
                sleep 2
              done
              echo "ERROR: genesis service did not become ready"
              exit 1

        # ── 2. Fetch genesis artefacts to /shared ──────────────────────
        # ethpandaops generator 4.x+ writes ALL artefacts to /metadata/.
        # We mirror that whole directory locally so lighthouse / prysm /
        # teku can use --testnet-dir=/shared/metadata directly, matching
        # the upstream tool convention. We also extract the EL genesis
        # to /shared/el-genesis.json for geth/reth/erigon init steps.
        - name: fetch-genesis
          image: {{ $ctx.Values.peerTable.image }}
          imagePullPolicy: IfNotPresent
          command: [/bin/sh, -c]
          args:
            - |
              set -e
              mkdir -p /shared/metadata /shared/cl-config
              # Slurp full metadata/ tree (genesis.json, genesis.ssz, config.yaml, ...)
              cd /shared/metadata
              wget -q -r -nH --cut-dirs=1 --no-parent "{{ $genesisUrl }}/metadata/" || true
              cd /
              # Keep legacy paths for backwards compatibility with templates
              # that referenced /shared/cl-config and /shared/el-genesis.json.
              cp /shared/metadata/genesis.json /shared/el-genesis.json
              cp -r /shared/metadata/. /shared/cl-config/
              # Lighthouse needs deploy_block.txt; alias from deposit_contract_block.txt.
              if [ -f /shared/cl-config/deposit_contract_block.txt ] && [ ! -f /shared/cl-config/deploy_block.txt ]; then
                cp /shared/cl-config/deposit_contract_block.txt /shared/cl-config/deploy_block.txt
              fi
              if [ -f /shared/metadata/deposit_contract_block.txt ] && [ ! -f /shared/metadata/deploy_block.txt ]; then
                cp /shared/metadata/deposit_contract_block.txt /shared/metadata/deploy_block.txt
              fi
              {{- if $isValidator }}
              # legacy validator keys tar — may be absent in newer generator versions
              curl -fsSL "{{ $genesisUrl }}/validators/keys.tar" -o /shared/validator-keys.tar || true
              {{- if $vcOrdinal }}
              # vc-keystores: fetch this node's tar and untar to /shared.
              mkdir -p /shared/vc-keystores
              if curl -fsSL "{{ $genesisUrl }}/vc-keystores/node{{ $vcOrdinal }}.tar" \
                   -o /tmp/vc.tar; then
                tar -C /shared/vc-keystores -xf /tmp/vc.tar
                rm -f /tmp/vc.tar
                ls -la /shared/vc-keystores/node{{ $vcOrdinal }} 2>/dev/null | head
              else
                echo "vc-keystores/node{{ $vcOrdinal }}.tar not present — vc sidecar will skip"
              fi
              {{- end }}
              {{- end }}
              ls -la /shared /shared/cl-config
          volumeMounts:
            - { name: shared, mountPath: /shared }
        {{- end }}

        # ── 3. Derive P2P key from mnemonic ────────────────────────────
        # Same algorithm as the peer-table Job (derive.py) so the enode /
        # libp2p peer ID it publishes for this node matches what this node
        # actually starts up with.
        #
        # CL_OUT path & format are client-specific so lighthouse / prysm / teku
        # each pick up the derived key from the exact location they expect
        # without needing CLI flags (most don't expose a path override).
        #
        #   lighthouse: <datadir>/beacon/network/key   raw 32-byte binary
        #   prysm:      <datadir>/network-keys         32-byte hex string
        #   teku:       <datadir>/p2p-key              "0x" + protobuf-hex
        {{- if $deriveP2p }}
        {{- $clOut := printf "%s/p2p-secret" $node.cl.dataPath -}}
        {{- if eq $node.cl.client "lighthouse" -}}
        {{- $clOut = printf "%s/beacon/network/key" $node.cl.dataPath -}}
        {{- else if eq $node.cl.client "prysm" -}}
        {{- $clOut = printf "%s/network-keys" $node.cl.dataPath -}}
        {{- else if eq $node.cl.client "teku" -}}
        {{- $clOut = printf "%s/p2p-key" $node.cl.dataPath -}}
        {{- end }}
        - name: derive-p2p-key
          image: {{ $ctx.Values.peerTable.deriveImage }}
          imagePullPolicy: IfNotPresent
          env:
            - { name: EL_INDEX,  value: {{ $elIdx | quote }} }
            - { name: CL_INDEX,  value: {{ $clIdx | quote }} }
            - { name: EL_OUT,    value: "{{ $node.el.dataPath }}/nodekey" }
            - { name: CL_OUT,    value: {{ $clOut | quote }} }
            - { name: CL_FORMAT, value: {{ $node.cl.client | quote }} }
            - name: MNEMONIC
              valueFrom:
                secretKeyRef:
                  name: {{ $rel }}-mnemonic
                  key: mnemonic
          command: [/bin/sh, -c]
          args:
            - |
              set -eu
              pip install --quiet --no-cache-dir eth-account==0.13.4 base58==2.1.1
              python3 /scripts/derive.py --mode keys
          volumeMounts:
            - { name: data-el, mountPath: {{ $node.el.dataPath }} }
            - { name: data-cl, mountPath: {{ $node.cl.dataPath }} }
            - { name: script, mountPath: /scripts }
        {{- end }}

        # ── 4. EL chain-init (devnet / join.custom) ────────────────────
        {{- if $needsGenesisFetch }}
        - name: el-init
          image: {{ $node.el.image.repository }}:{{ $node.el.image.tag }}
          imagePullPolicy: {{ $node.el.image.pullPolicy | default "IfNotPresent" }}
          command: [/bin/sh, -c]
          args:
            - |
              set -e
              if [ -f {{ $node.el.dataPath }}/.initialized ]; then
                echo "EL already initialized, skipping"
                exit 0
              fi
              {{- if eq $node.el.client "geth" }}
              geth init --datadir {{ $node.el.dataPath }} /shared/el-genesis.json
              {{- else if eq $node.el.client "reth" }}
              reth init --datadir {{ $node.el.dataPath }} --chain /shared/el-genesis.json
              {{- else if eq $node.el.client "erigon" }}
              erigon init --datadir {{ $node.el.dataPath }} /shared/el-genesis.json
              {{- else if eq $node.el.client "nethermind" }}
              echo "nethermind reads genesis at runtime; nothing to init"
              {{- else if eq $node.el.client "besu" }}
              echo "besu reads genesis at runtime via --genesis-file; nothing to init"
              {{- else }}
              echo "WARNING: no el-init recipe for client {{ $node.el.client }}"
              {{- end }}
              touch {{ $node.el.dataPath }}/.initialized
          volumeMounts:
            - { name: data-el, mountPath: {{ $node.el.dataPath }} }
            - { name: shared,  mountPath: /shared }
        {{- end }}

        # ── 5. Generate shared JWT secret ──────────────────────────────
        - name: gen-jwt
          image: {{ $ctx.Values.peerTable.image }}
          imagePullPolicy: IfNotPresent
          command: [/bin/sh, -c]
          args:
            - |
              set -e
              if [ ! -f /jwt/jwtsecret ]; then
                head -c 32 /dev/urandom | od -A n -t x1 | tr -d ' \n' > /jwt/jwtsecret
                echo "JWT secret generated"
              fi
          volumeMounts:
            - { name: jwt, mountPath: /jwt }

        # ── 6. Wait for peer-table ConfigMap, then apply to EL data dir ─
        # The wait loop is necessary because the peer-table Job runs in
        # parallel with sts creation and may produce the ConfigMap after the
        # node pod starts. The configMap volume is marked optional so the
        # pod can start; this init blocks until the data actually arrives.
        #
        # For geth we drop the enode list into the standard static-nodes.json
        # location — it is auto-loaded on EL boot, zero command changes needed.
        # For other EL/CL clients, the CSV forms at /peers/*.csv are available
        # for the user's command to reference via `commandShell: true`, e.g.:
        #   reth node ... --trusted-peers $(cat /peers/el-static-nodes.csv)
        {{- if $peerTable }}
        - name: wait-and-apply-peer-table
          image: {{ $ctx.Values.peerTable.image }}
          imagePullPolicy: IfNotPresent
          command: [/bin/sh, -c]
          args:
            - |
              set -e
              for i in $(seq 1 120); do
                if [ -s /peers-cm/el-static-nodes.txt ]; then
                  echo "Peer table ready"
                  break
                fi
                sleep 2
              done
              if [ ! -s /peers-cm/el-static-nodes.txt ]; then
                echo "ERROR: peer table did not appear"
                exit 1
              fi
              # Copy raw artefacts from readonly ConfigMap mount into writable emptyDir
              # so we can derive CSV forms and clients can also write transient state.
              cp /peers-cm/el-static-nodes.txt  /peers/
              cp /peers-cm/el-static-nodes.json /peers/
              cp /peers-cm/cl-trusted-peers.txt /peers/
              # CSV forms for clients that consume comma-separated peer lists.
              tr '\n' ',' < /peers/el-static-nodes.txt | sed 's/,$//' > /peers/el-static-nodes.csv
              tr '\n' ',' < /peers/cl-trusted-peers.txt | sed 's/,$//' > /peers/cl-trusted-peers.csv
              # geth: static-nodes.json was deprecated in v1.16. Build a
              # config.toml with [Node.P2P] StaticNodes/TrustedNodes pointing
              # at every node in the release. The geth command must then
              # include --config=/peers/geth-config.toml.
              {{- if eq $node.el.client "geth" }}
              {
                echo "[Node.P2P]"
                echo "StaticNodes = ["
                awk 'NF{printf "  \"%s\",\n", $0}' /peers/el-static-nodes.txt | sed '$s/,$//'
                echo "]"
                echo "TrustedNodes = ["
                awk 'NF{printf "  \"%s\",\n", $0}' /peers/el-static-nodes.txt | sed '$s/,$//'
                echo "]"
              } > /peers/geth-config.toml
              echo "geth config.toml written:"
              cat /peers/geth-config.toml
              {{- end }}
              # nethermind: install StaticNodes.json under DATADIR.
              {{- if eq $node.el.client "nethermind" }}
              mkdir -p {{ $node.el.dataPath }}
              cp /peers/el-static-nodes.json {{ $node.el.dataPath }}/StaticNodes.json
              {{- end }}
              {{- if or (eq $node.el.client "reth") (eq $node.el.client "erigon") (eq $node.el.client "besu") }}
              # {{ $node.el.client }} has no drop-in static-nodes file format.
              # Your node command must reference /peers/el-static-nodes.csv, e.g.:
              #   reth   ... --trusted-peers $(cat /peers/el-static-nodes.csv)
              #   erigon ... --staticpeers   $(cat /peers/el-static-nodes.csv)
              #   besu   ... --static-nodes-file=/peers/el-static-nodes.json
              # Make sure commandShell: true is set on the node so $(...) expands.
              {{- end }}
              ls -la /peers
          volumeMounts:
            - { name: peers-cm, mountPath: /peers-cm, readOnly: true }
            - { name: peers,    mountPath: /peers }
            - { name: data-el,  mountPath: {{ $node.el.dataPath }} }
        {{- end }}

        # ── 7. CL peer discovery (follower nodes only) ──────────────
        # Asymmetric bootstrap to break the chicken-and-egg of "both nodes
        # only know each other's peer ID; neither dials first". The cluster's
        # first role=validator node ({{ $clLeaderName | default "<none>" }}) is the
        # leader and starts with no boot-nodes. Every other node fetches the
        # leader's live ENR from its beacon HTTP API and writes it to
        # /shared/cl-bootnodes.txt for the cl container to load.
        {{- if $needsClBootstrap }}
        - name: cl-peer-discovery
          image: {{ $ctx.Values.peerTable.image }}
          imagePullPolicy: IfNotPresent
          command: [/bin/sh, -c]
          args:
            - |
              set -e
              LEADER="{{ $ctx.Release.Name }}-{{ $clLeaderName }}"
              echo "Resolving CL leader $LEADER:5052/eth/v1/node/identity ..."
              for attempt in $(seq 1 30); do
                BODY=$(curl -fsS --max-time 5 "http://${LEADER}:5052/eth/v1/node/identity" 2>/dev/null || true)
                ENR=$(echo "$BODY" | sed -n 's/.*"enr":"\(enr:[^"]*\)".*/\1/p')
                if [ -n "$ENR" ]; then
                  echo "$ENR" > /shared/cl-bootnodes.txt
                  echo "Got leader ENR (try $attempt): $ENR"
                  exit 0
                fi
                echo "leader not ready yet (try $attempt), retrying in 5s..."
                sleep 5
              done
              echo "WARN: leader didn't respond within 150s — starting without boot-nodes (will rely on inbound)"
              : > /shared/cl-bootnodes.txt
          volumeMounts:
            - { name: shared, mountPath: /shared }
        {{- end }}

      containers:
        # ── EL ────────────────────────────────────────────────────────
        - name: el
          image: {{ $node.el.image.repository }}:{{ $node.el.image.tag }}
          imagePullPolicy: {{ $node.el.image.pullPolicy | default "IfNotPresent" }}
          {{- if $node.el.commandShell }}
          command: ["/bin/sh", "-c"]
          args: {{ toYaml $node.el.command | nindent 12 }}
          {{- else }}
          command: {{ toYaml $node.el.command | nindent 12 }}
          {{- end }}
          ports:
            # Prefix with el- so EL and CL ports never collide within the pod
            # (k8s rejects duplicate names across containers in the same pod).
            # service-nodes.yaml uses the same prefix scheme.
            {{- range $node.el.ports }}
            - { name: el-{{ .name }}, containerPort: {{ .port }} }
            {{- end }}
          {{- with $node.el.resources }}
          resources: {{- toYaml . | nindent 12 }}
          {{- end }}
          volumeMounts:
            - { name: data-el, mountPath: {{ $node.el.dataPath }} }
            - { name: jwt, mountPath: /jwt }
            {{- if $needsGenesisFetch }}
            - { name: shared, mountPath: /shared }
            {{- end }}
            {{- if $peerTable }}
            - { name: peers, mountPath: /peers }
            {{- end }}

        # ── CL ────────────────────────────────────────────────────────
        - name: cl
          image: {{ $node.cl.image.repository }}:{{ $node.cl.image.tag }}
          imagePullPolicy: {{ $node.cl.image.pullPolicy | default "IfNotPresent" }}
          # POD_IP is required by lighthouse / prysm / teku to advertise
          # their actual reachable IPv4 in the ENR (without --enr-address,
          # the ENR's ip4 field is None and remote peers can't dial back).
          # The downward API populates it on every pod start.
          env:
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
          {{- if $node.cl.commandShell }}
          command: ["/bin/sh", "-c"]
          args: {{ toYaml $node.cl.command | nindent 12 }}
          {{- else }}
          command: {{ toYaml $node.cl.command | nindent 12 }}
          {{- end }}
          ports:
            {{- range $node.cl.ports }}
            - { name: cl-{{ .name }}, containerPort: {{ .port }} }
            {{- end }}
          {{- with $node.cl.resources }}
          resources: {{- toYaml . | nindent 12 }}
          {{- end }}
          volumeMounts:
            - { name: data-cl, mountPath: {{ $node.cl.dataPath }} }
            - { name: jwt, mountPath: /jwt }
            {{- if $needsGenesisFetch }}
            - { name: shared, mountPath: /shared }
            {{- end }}
            {{- if $peerTable }}
            - { name: peers, mountPath: /peers }
            {{- end }}

        # ── VC ──────────────────────────────────────────────────────
        # Validator client sidecar. Only emitted for role=validator nodes
        # whose CL client supports automatic key derivation. Reads vc
        # keystores fetched into /shared/vc-keystores/nodeN.
        {{- if and $isValidator $vcOrdinal $needsGenesisFetch }}
        # vc image: prefer node.cl.vcImage when set (some CLs ship the
        # validator binary in a separate image, e.g. docker-hub-published
        # prysm uses prysmaticlabs/prysm-beacon-chain vs prysm-validator).
        # Fallback to cl.image which works for lighthouse / teku.
        {{- $vcImage := $node.cl.image }}
        {{- if $node.cl.vcImage }}{{ $vcImage = $node.cl.vcImage }}{{- end }}
        - name: vc
          image: {{ $vcImage.repository }}:{{ $vcImage.tag }}
          imagePullPolicy: {{ $vcImage.pullPolicy | default "IfNotPresent" }}
          command: [/bin/sh, -c]
          args:
            - |
              set -e
              {{- if eq $node.cl.client "lighthouse" }}
              SRC="/shared/vc-keystores/node{{ $vcOrdinal }}"
              if [ ! -f /vc-data/validators/validator_definitions.yml ] 2>/dev/null && [ -d "$SRC/keys" ]; then
                mkdir -p /vc-data/validators /vc-data/secrets
                for d in $(ls "$SRC/keys" 2>/dev/null); do
                  cp -r "$SRC/keys/$d" /vc-data/validators/ 2>/dev/null || true
                  [ -f "$SRC/secrets/$d" ] && cp "$SRC/secrets/$d" /vc-data/secrets/ 2>/dev/null || true
                done
                INIT_SLASHING="--init-slashing-protection"
              else
                INIT_SLASHING=""
              fi
              # Note: lighthouse vc has its own beacon-node retry loop; no
              # external wait needed (and the lighthouse image has neither
              # curl nor wget, so a shell-side wait isn't possible anyway).
              exec lighthouse vc \
                --testnet-dir=/shared/metadata \
                --datadir=/vc-data \
                --beacon-nodes=http://127.0.0.1:5052 \
                --suggested-fee-recipient=0x0000000000000000000000000000000000000000 \
                --metrics --metrics-address=0.0.0.0 --metrics-port=5064 \
                $INIT_SLASHING
              {{- else if eq $node.cl.client "prysm" }}
              SRC="/shared/vc-keystores/node{{ $vcOrdinal }}/prysm"
              WALLET_PW=/vc-data/wallet-password.txt
              echo -n devnet > $WALLET_PW
              # prysm vc retries beacon-rpc-provider internally with backoff,
              # so a shell-side wait isn't needed. Older revisions of this
              # template used `until wget …` which silently hangs forever on
              # distroless validator images (ethpandaops's build has no wget).
              # docker-hub `prysmaticlabs/prysm-validator` image puts the
              # binary at /validator; gcr `prysm/validator` keeps it at
              # /app/cmd/validator/validator. Probe both.
              VBIN=/validator
              [ -x /app/cmd/validator/validator ] && VBIN=/app/cmd/validator/validator
              exec $VBIN \
                --datadir=/vc-data \
                --beacon-rpc-provider=127.0.0.1:4000 \
                --wallet-dir="$SRC" \
                --wallet-password-file="$WALLET_PW" \
                --chain-config-file=/shared/metadata/config.yaml \
                --monitoring-host=0.0.0.0 --monitoring-port=5064 \
                --accept-terms-of-use
              {{- else if eq $node.cl.client "teku" }}
              SRC="/shared/vc-keystores/node{{ $vcOrdinal }}/teku"
              until wget -q -O- http://127.0.0.1:5052/eth/v1/node/version >/dev/null 2>&1; do sleep 2; done
              exec /opt/teku/bin/teku validator-client \
                --network=/shared/metadata/config.yaml \
                --data-base-path=/vc-data \
                --beacon-node-api-endpoint=http://127.0.0.1:5052 \
                --validator-keys="$SRC/keys:$SRC/secrets" \
                --metrics-enabled --metrics-port=5064 --metrics-host-allowlist=*
              {{- else }}
              echo "vc container is not implemented for cl.client={{ $node.cl.client }}"
              sleep infinity
              {{- end }}
          env:
            - { name: HOME, value: /vc-data }
          ports:
            - { name: vc-metric, containerPort: 5064 }
          resources:
            requests: { cpu: 100m, memory: 256Mi }
            limits:   { cpu: 500m, memory: 512Mi }
          volumeMounts:
            - { name: vc-data, mountPath: /vc-data }
            - { name: shared, mountPath: /shared }
        {{- end }}

  volumeClaimTemplates:
    - metadata:
        name: data-el
      spec:
        accessModes: ["ReadWriteOnce"]
        {{- with (or $node.el.persistence.storageClassName $ctx.Values.storageClass) }}
        storageClassName: {{ . }}
        {{- end }}
        resources:
          requests:
            storage: {{ $node.el.persistence.size }}
    - metadata:
        name: data-cl
      spec:
        accessModes: ["ReadWriteOnce"]
        {{- with (or $node.cl.persistence.storageClassName $ctx.Values.storageClass) }}
        storageClassName: {{ . }}
        {{- end }}
        resources:
          requests:
            storage: {{ $node.cl.persistence.size }}
{{- end }}
