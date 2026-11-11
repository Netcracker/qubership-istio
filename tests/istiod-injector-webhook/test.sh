#!/usr/bin/env bash
set -euo pipefail

# Verifies, from rendered manifests only, that the chart installs no sidecar injector webhook
# and keeps the validating webhooks and the istio-sidecar-injector ConfigMap. The flag comes
# from the Istio operator, so the last check fails if an Istio bump drops it.

RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "${RENDER_DIR}"' EXIT

render() {
  local out="$1"
  shift
  helm template "${HELM_RELEASE}" "${HELM_CHART_PATH}" --namespace "${ISTIO_NAMESPACE}" "$@" > "${RENDER_DIR}/${out}.yaml"
}

# count <render> <kind> [name]
count() {
  yq -r "select(.kind == \"$2\" and ((\"$3\" == \"\") or .metadata.name == \"$3\")) | .kind" "${RENDER_DIR}/$1.yaml" | grep -c . || true
}

expect() {
  local what="$1" got="$2" want="$3"
  [[ "${got}" == "${want}" ]] || fail "${what}: expected '${want}', got '${got}'"
}

render default
expect "MutatingWebhookConfiguration" "$(count default MutatingWebhookConfiguration)" "0"
expect "ValidatingWebhookConfiguration" "$(count default ValidatingWebhookConfiguration)" "2"
expect "istio-sidecar-injector ConfigMap" "$(count default ConfigMap istio-sidecar-injector)" "1"

render with-webhook --set global.operatorManageWebhooks=false
expect "MutatingWebhookConfiguration with operatorManageWebhooks=false" "$(count with-webhook MutatingWebhookConfiguration)" "1"

echo "All istiod-injector-webhook checks passed"
