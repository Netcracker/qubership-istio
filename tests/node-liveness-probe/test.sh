#!/usr/bin/env bash
set -euo pipefail

# Verifies, from rendered manifests only, what the chart adds to the node agents on top of
# upstream:
#   - a liveness probe on the install-cni container of istio-cni-node and on the istio-proxy
#     container of ztunnel, next to the upstream readiness probes, which stay as they are;
#   - the node-inotify init container still runs in both DaemonSets;
#   - null switches each probe off on its own, and a resource scope that leaves the
#     DaemonSets out still renders nothing.

RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "${RENDER_DIR}"' EXIT

render() {
  local out="$1"
  shift
  helm template "${HELM_RELEASE}" "${HELM_CHART_PATH}" --namespace "${ISTIO_NAMESPACE}" "$@" > "${RENDER_DIR}/${out}.yaml"
}

# query <render> <daemonset name> <container name> <yq path below the container>
query() {
  yq -r "select(.kind == \"DaemonSet\" and .metadata.name == \"$2\") | .spec.template.spec.containers[] | select(.name == \"$3\") | $4" "${RENDER_DIR}/$1.yaml"
}

# init_containers <render> <daemonset name>
init_containers() {
  yq -r "select(.kind == \"DaemonSet\" and .metadata.name == \"$2\") | .spec.template.spec.initContainers[].name" "${RENDER_DIR}/$1.yaml"
}

count() {
  yq -r "select(.kind == \"DaemonSet\" and (.metadata.name == \"istio-cni-node\" or .metadata.name == \"ztunnel\")) | .kind" "${RENDER_DIR}/$1.yaml" | grep -c . || true
}

expect() {
  local what="$1" got="$2" want="$3"
  [[ "${got}" == "${want}" ]] || fail "${what}: expected '${want}', got '${got}'"
}

# --- 1. Defaults: the probes are there, and the readiness probes are unchanged ---
render default
expect "cni liveness probe" "$(query default istio-cni-node install-cni '.livenessProbe.tcpSocket.port')" "8000"
expect "cni readiness probe" "$(query default istio-cni-node install-cni '.readinessProbe.httpGet.path')" "/readyz"
expect "ztunnel liveness probe" "$(query default ztunnel istio-proxy '.livenessProbe.tcpSocket.port')" "15021"
expect "ztunnel readiness probe" "$(query default ztunnel istio-proxy '.readinessProbe.httpGet.path')" "/healthz/ready"
expect "cni liveness timing" "$(query default istio-cni-node install-cni '.livenessProbe.failureThreshold')" "5"
expect "ztunnel liveness timing" "$(query default ztunnel istio-proxy '.livenessProbe.failureThreshold')" "5"

# --- 2. The node-inotify init container is still there, next to the probes ---
expect "cni init containers" "$(init_containers default istio-cni-node | grep -c node-inotify-tuning)" "1"
expect "ztunnel init containers" "$(init_containers default ztunnel | grep -c node-inotify-tuning)" "1"

# --- 3. null switches each probe off, and only its own ---
render no-cni-probe --set cni.livenessProbe=null
expect "cni liveness probe with cni.livenessProbe=null" "$(query no-cni-probe istio-cni-node install-cni 'has("livenessProbe")')" "false"
expect "ztunnel liveness probe with cni.livenessProbe=null" "$(query no-cni-probe ztunnel istio-proxy '.livenessProbe.tcpSocket.port')" "15021"

render no-ztunnel-probe --set ztunnel.livenessProbe=null
expect "ztunnel liveness probe with ztunnel.livenessProbe=null" "$(query no-ztunnel-probe ztunnel istio-proxy 'has("livenessProbe")')" "false"
expect "cni liveness probe with ztunnel.livenessProbe=null" "$(query no-ztunnel-probe istio-cni-node install-cni '.livenessProbe.tcpSocket.port')" "8000"

# --- 4. A scope without the DaemonSets still renders, without them ---
render cluster-scope --set global.resourceScope=cluster
expect "DaemonSets with resourceScope=cluster" "$(count cluster-scope)" "0"

echo "All node-liveness-probe checks passed"
