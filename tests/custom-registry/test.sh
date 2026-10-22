#!/usr/bin/env bash
set -euo pipefail

# Verifies, from rendered manifests only, that a registry the parent chart supplies through
# custom.docker.registry reaches every Istio image, although the chart values set
# global.hub and ztunnel.hub to docker.io/istio:
#   - without a parent registry the images stay on docker.io/istio;
#   - with one, istiod, istio-cni-node, ztunnel, and the gateway proxy hub take it;
#   - it also wins over a hub set in the values.
# The parent chart is simulated by a copy of the chart with the helper defined.

RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "${RENDER_DIR}"' EXIT

REGISTRY="registry.example.com/istio"

PARENT_CHART="${RENDER_DIR}/chart"
cp -r "${HELM_CHART_PATH}" "${PARENT_CHART}"
cat > "${PARENT_CHART}/templates/_test-registry.tpl" <<TPL
{{- define "custom.docker.registry" -}}${REGISTRY}{{- end -}}
TPL

render() {
  local out="$1" chart="$2"
  shift 2
  helm template "${HELM_RELEASE}" "${chart}" --namespace "${ISTIO_NAMESPACE}" "$@" > "${RENDER_DIR}/${out}.yaml"
}

# image <render> <kind> <name>: the image of the first container.
image() {
  yq -r "select(.kind == \"$2\" and .metadata.name == \"$3\") | .spec.template.spec.containers[0].image" "${RENDER_DIR}/$1.yaml"
}

# The hub istiod gives the gateways it creates.
gateway_hub() {
  yq -r 'select(.kind == "ConfigMap" and .metadata.name == "istio-sidecar-injector") | .data.values | from_yaml | .global.hub' "${RENDER_DIR}/$1.yaml"
}

expect() {
  local what="$1" got="$2" want="$3"
  [[ "${got}" == "${want}" ]] || fail "${what}: expected '${want}', got '${got}'"
}

# expect_hub <render> <hub>: every Istio image and the gateway hub start with <hub>.
expect_hub() {
  expect "$1: istiod image" "$(image "$1" Deployment istiod | sed 's|/pilot:.*||')" "$2"
  expect "$1: istio-cni-node image" "$(image "$1" DaemonSet istio-cni-node | sed 's|/install-cni:.*||')" "$2"
  expect "$1: ztunnel image" "$(image "$1" DaemonSet ztunnel | sed 's|/ztunnel:.*||')" "$2"
  expect "$1: gateway hub" "$(gateway_hub "$1")" "$2"
}

# --- 1. No parent registry: the chart default ---
render shipped "${HELM_CHART_PATH}"
expect_hub shipped "docker.io/istio"

# --- 2. A parent registry replaces the default hubs ---
render parent "${PARENT_CHART}"
expect_hub parent "${REGISTRY}"

# --- 3. It also wins over hubs set in the values ---
render parent-with-hubs "${PARENT_CHART}" --set global.hub=other.example.com/istio --set ztunnel.hub=other.example.com/istio
expect_hub parent-with-hubs "${REGISTRY}"

echo "All custom-registry checks passed"
