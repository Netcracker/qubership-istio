#!/usr/bin/env bash
set -euo pipefail

# Verifies, from rendered manifests only, what the chart adds to istiod on top of upstream:
#   - the name, app.kubernetes.io/component and app.kubernetes.io/technology labels on the
#     Deployment, its pods, and the Service (name only), with the selector left as upstream;
#   - the liveness probe of the discovery container, next to the upstream readiness probe;
#   - null switches both off, and a Deployment or Service the resource scope leaves out
#     still renders nothing.

RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "${RENDER_DIR}"' EXIT

render() {
  local out="$1"
  shift
  helm template "${HELM_RELEASE}" "${HELM_CHART_PATH}" --namespace "${ISTIO_NAMESPACE}" "$@" > "${RENDER_DIR}/${out}.yaml"
}

# query <render> <kind> <yq path below the object>
query() {
  yq -r "select(.kind == \"$2\" and .metadata.name == \"istiod\") | $3" "${RENDER_DIR}/$1.yaml"
}

count() {
  yq -r "select(.kind == \"$2\" and .metadata.name == \"istiod\") | .kind" "${RENDER_DIR}/$1.yaml" | grep -c . || true
}

expect() {
  local what="$1" got="$2" want="$3"
  [[ "${got}" == "${want}" ]] || fail "${what}: expected '${want}', got '${got}'"
}

# The three labels of an object, joined: "<name>,<component>,<technology>". Built from strings:
# an array would also print an empty line for every document the select drops.
LABELS='.name + "," + .["app.kubernetes.io/component"] + "," + .["app.kubernetes.io/technology"]'

# --- 1. Defaults: labels and the liveness probe are there ---
render default
expect "Deployment labels" "$(query default Deployment ".metadata.labels | ${LABELS}")" "istiod,controller,go"
expect "pod labels" "$(query default Deployment ".spec.template.metadata.labels | ${LABELS}")" "istiod,controller,go"
expect "Service name label" "$(query default Service '.metadata.labels.name')" "istiod"
expect "Service keeps the upstream labels" "$(query default Service '.metadata.labels["app.kubernetes.io/name"]')" "istiod"
expect "selector" "$(query default Deployment '.spec.selector.matchLabels | to_entries | map(.key + "=" + .value) | join(",")')" "istio=pilot"
expect "liveness probe" "$(query default Deployment '.spec.template.spec.containers[] | select(.name == "discovery") | .livenessProbe.tcpSocket.port')" "8080"
expect "readiness probe" "$(query default Deployment '.spec.template.spec.containers[] | select(.name == "discovery") | .readinessProbe.httpGet.path')" "/ready"
expect "PLATFORM keeps its empty string" "$(query default Deployment '.spec.template.spec.containers[] | select(.name == "discovery") | .env[] | select(.name == "PLATFORM") | .value | tag')" "!!str"

# --- 2. null switches them off; an empty map would only merge with the defaults ---
render no-probe --set istiod.livenessProbe=null
expect "liveness probe with livenessProbe=null" "$(query no-probe Deployment '.spec.template.spec.containers[] | select(.name == "discovery") | has("livenessProbe")')" "false"

render no-service-labels --set istiod.serviceLabels=null
expect "Service name label with serviceLabels=null" "$(query no-service-labels Service '.metadata.labels.name')" "null"

render custom-component --set 'istiod.deploymentLabels.app\.kubernetes\.io/component=backend'
expect "overridden component label" "$(query custom-component Deployment '.metadata.labels["app.kubernetes.io/component"]')" "backend"

# --- 3. A scope without the Deployment and the Service still renders, without them ---
render cluster-scope --set global.resourceScope=cluster
expect "Deployment with resourceScope=cluster" "$(count cluster-scope Deployment)" "0"
expect "Service with resourceScope=cluster" "$(count cluster-scope Service)" "0"

echo "All istiod-labels-probe checks passed"
