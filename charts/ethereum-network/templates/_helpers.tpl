{{/*
Chart name.
*/}}
{{- define "ethereum-network.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully-qualified release name. Used as the resource-name prefix everywhere.
*/}}
{{- define "ethereum-network.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "ethereum-network.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Standard labels applied to all resources. Selector labels match the legacy
`app:` key used by the reference manifests.
*/}}
{{- define "ethereum-network.labels" -}}
helm.sh/chart: {{ include "ethereum-network.chart" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
─── Mode flags ─────────────────────────────────────────────────────────────
Each returns the literal string "true" when active; empty otherwise.
Helm treats a non-empty string as truthy, so usage is:
    {{- if include "ethereum-network.isDevnet" . }} ...
*/}}

{{- define "ethereum-network.isDevnet" -}}
{{- if eq .Values.mode "devnet" -}}true{{- end -}}
{{- end }}

{{- define "ethereum-network.isJoin" -}}
{{- if eq .Values.mode "join" -}}true{{- end -}}
{{- end }}

{{- define "ethereum-network.isJoinPublic" -}}
{{- if and (eq .Values.mode "join") (eq .Values.join.source "public") -}}true{{- end -}}
{{- end }}

{{- define "ethereum-network.isJoinCustom" -}}
{{- if and (eq .Values.mode "join") (eq .Values.join.source "custom") -}}true{{- end -}}
{{- end }}

{{/*
True when a genesis service should be rendered in this release (devnet only).
join.custom fetches genesis from an external service so no local genesis sts.
*/}}
{{- define "ethereum-network.needsGenesis" -}}
{{- if include "ethereum-network.isDevnet" . -}}true{{- end -}}
{{- end }}

{{/*
True when PostgreSQL should be deployed. Only Blockscout requires it; Dora
uses its own sqlite-backed PVC.
*/}}
{{- define "ethereum-network.needsPostgres" -}}
{{- if or .Values.postgres.enabled .Values.blockscout.enabled -}}true{{- end -}}
{{- end }}

{{/*
EL endpoint URL of a named node (or the CL leader when name is empty),
formatted as http://{release}-{node}:8545. Used by otterscan / spamoor
to point at a stable EL inside the release.

Call signature: include "ethereum-network.elEndpoint" (dict "name" $name "ctx" $)
*/}}
{{- define "ethereum-network.elEndpoint" -}}
{{- $name := .name -}}
{{- if not $name -}}
{{- $name = include "ethereum-network.clLeaderName" .ctx -}}
{{- end -}}
{{- printf "http://%s-%s:8545" .ctx.Release.Name $name -}}
{{- end }}

{{/*
VMServiceScrape is rendered only when the CRD is installed AND the feature
flag is on. This lets the chart cohabit with clusters that have no
VictoriaMetrics operator.
*/}}
{{- define "ethereum-network.vmScrapeEnabled" -}}
{{- if and .Values.vmServiceScrape.enabled (.Capabilities.APIVersions.Has "operator.victoriametrics.com/v1beta1/VMServiceScrape") -}}true{{- end -}}
{{- end }}

{{/*
The peer-table Job runs when:
  - peerTable.enabled is true, AND
  - we have a shared mnemonic to derive from — devnet always, join.custom
    only if a mnemonic was provided.
join.public always disables it (public network membership is via DHT).
*/}}
{{- define "ethereum-network.peerTableEnabled" -}}
{{- if .Values.peerTable.enabled -}}
  {{- if include "ethereum-network.isDevnet" . -}}true{{- end -}}
  {{- if and (include "ethereum-network.isJoinCustom" .) .Values.join.custom.mnemonic -}}true{{- end -}}
{{- end -}}
{{- end }}

{{/*
Mnemonic precedence resolution. Returns the empty string when no mnemonic is
available (e.g. mode=join.public) — callers must check before using.
*/}}
{{- define "ethereum-network.effectiveMnemonic" -}}
{{- if include "ethereum-network.isDevnet" . -}}
{{- .Values.devnet.genesisGenerator.mnemonic -}}
{{- else if include "ethereum-network.isJoinCustom" . -}}
{{- .Values.join.custom.mnemonic | default .Values.mnemonic -}}
{{- else -}}
{{- .Values.mnemonic -}}
{{- end -}}
{{- end }}

{{/*
Genesis service URL used by node init containers.
  devnet      → in-cluster nginx service
  join.custom → user-provided URL
  join.public → empty (no fetch step)
*/}}
{{- define "ethereum-network.genesisUrl" -}}
{{- if include "ethereum-network.isDevnet" . -}}
http://{{ include "ethereum-network.fullname" . }}-genesis
{{- else if include "ethereum-network.isJoinCustom" . -}}
{{- .Values.join.custom.genesisUrl -}}
{{- end -}}
{{- end }}

{{/*
Built-in checkpoint sync URLs for public Ethereum networks.
*/}}
{{- define "ethereum-network.defaultCheckpointUrl" -}}
{{- $net := .Values.join.public.network -}}
{{- if eq $net "mainnet" -}}https://beaconstate.info
{{- else if eq $net "sepolia" -}}https://sepolia.beaconstate.info
{{- else if eq $net "holesky" -}}https://holesky.beaconstate.info
{{- else if eq $net "hoodi" -}}https://hoodi.beaconstate.info
{{- end -}}
{{- end }}

{{/*
Effective checkpoint URL — explicit override beats default.
*/}}
{{- define "ethereum-network.effectiveCheckpointUrl" -}}
{{- if include "ethereum-network.isJoinPublic" . -}}
{{- .Values.join.public.checkpointSyncUrl | default (include "ethereum-network.defaultCheckpointUrl" .) -}}
{{- else if include "ethereum-network.isJoinCustom" . -}}
{{- .Values.join.custom.checkpointSyncUrl -}}
{{- end -}}
{{- end }}

{{/*
HD index for the EL p2p key of a given node ordinal.
Call signature: include "ethereum-network.elKeyIndex" (dict "ordinal" $i "node" $n "ctx" $)
Honours per-node override.
*/}}
{{- define "ethereum-network.elKeyIndex" -}}
{{- $node := .node -}}
{{- if and $node.p2pKey $node.p2pKey.elIndexOverride -}}
{{- $node.p2pKey.elIndexOverride -}}
{{- else -}}
{{- add (int .ctx.Values.p2pKey.indexStart) (mul (int .ordinal) 2) -}}
{{- end -}}
{{- end }}

{{/*
HD index for the CL p2p key. Same signature as elKeyIndex.
*/}}
{{- define "ethereum-network.clKeyIndex" -}}
{{- $node := .node -}}
{{- if and $node.p2pKey $node.p2pKey.clIndexOverride -}}
{{- $node.p2pKey.clIndexOverride -}}
{{- else -}}
{{- add (int .ctx.Values.p2pKey.indexStart) (mul (int .ordinal) 2) 1 -}}
{{- end -}}
{{- end }}

{{/*
Deterministic 8-char domain suffix.
Call signature: include "ethereum-network.domainSuffix" (dict "release" X "svc" Y)
Algorithm: sha256 → trunc 8 → repeat 3 → b64enc → trunc 8 → lower
*/}}
{{- define "ethereum-network.domainSuffix" -}}
{{- $seed := printf "%s%s" .release .svc -}}
{{- $hex8 := $seed | sha256sum | trunc 8 -}}
{{- repeat 3 $hex8 | b64enc | trunc 8 | lower -}}
{{- end }}

{{/*
Build a fully-qualified ingress hostname.
Call signature: include "ethereum-network.host" (dict "release" X "svc" Y "port" Z "ctx" $)
*/}}
{{- define "ethereum-network.host" -}}
{{- if .ctx.Values.domainSuffixEnabled -}}
{{- $suffix := include "ethereum-network.domainSuffix" (dict "release" .release "svc" .svc) -}}
{{- printf "%s-%s-%s-%s.%s" .release .svc .port $suffix .ctx.Values.baseDomain -}}
{{- else -}}
{{- printf "%s-%s-%s.%s" .release .svc .port .ctx.Values.baseDomain -}}
{{- end -}}
{{- end }}

{{/*
Per-node resource name: {release}-{node.name}
*/}}
{{- define "ethereum-network.nodeName" -}}
{{- printf "%s-%s" .ctx.Release.Name .node.name | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/*
Stable in-cluster DNS name for a node's headless service. Used by the
peer-table Job to assemble enode / multiaddr URLs that survive pod restarts.
*/}}
{{- define "ethereum-network.nodeFQDN" -}}
{{- printf "%s-%s.%s.svc.cluster.local" .ctx.Release.Name .node.name .ctx.Release.Namespace -}}
{{- end }}

{{/*
Validator ordinal — 1-based position among role=validator entries in
.Values.nodes. Returns the empty string if the node is not a validator
(or the values.nodes list is missing). Drives which `nodeN/` keystore
subdirectory the genesis service produces for this node.

Call signature: include "ethereum-network.validatorOrdinal" (dict "node" $n "ctx" $)
*/}}
{{- define "ethereum-network.validatorOrdinal" -}}
{{- $target := .node -}}
{{- $count := 0 -}}
{{- $ordinal := "" -}}
{{- range $i, $n := .ctx.Values.nodes -}}
  {{- if eq $n.role "validator" -}}
    {{- $count = add1 $count -}}
    {{- if eq $n.name $target.name -}}
      {{- $ordinal = $count -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- $ordinal -}}
{{- end }}

{{/*
CL leader — the first role=validator entry in .Values.nodes. The leader
starts with no boot-nodes; every other node bootstraps off the leader's
ENR via the cl-peer-discovery init container. Returns the leader node name,
or empty string if no validator is configured.
*/}}
{{- define "ethereum-network.clLeaderName" -}}
{{- $leader := "" -}}
{{- range .Values.nodes -}}
  {{- if and (not $leader) (eq .role "validator") -}}
    {{- $leader = .name -}}
  {{- end -}}
{{- end -}}
{{- $leader -}}
{{- end }}

{{/*
True when the given node is the CL leader (the first validator).
Call signature: include "ethereum-network.isClLeader" (dict "node" $n "ctx" $)
*/}}
{{- define "ethereum-network.isClLeader" -}}
{{- $leader := include "ethereum-network.clLeaderName" .ctx -}}
{{- if and $leader (eq .node.name $leader) -}}true{{- end -}}
{{- end }}

{{/*
Total count of role=validator nodes in this release. The genesis
gen-vc-keystores init container loops 1..N to produce one keystore
subtree per validator pod.
*/}}
{{- define "ethereum-network.validatorCount" -}}
{{- $count := 0 -}}
{{- range .Values.nodes -}}
  {{- if eq .role "validator" -}}
    {{- $count = add1 $count -}}
  {{- end -}}
{{- end -}}
{{- $count -}}
{{- end }}
