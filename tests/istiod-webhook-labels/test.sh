#!/usr/bin/env bash
set -euo pipefail

# Verifies, from rendered manifests only, that the istio-sidecar-injector webhook configuration
# carries admissions.enforcer/disabled next to the labels upstream sets, and that a resource
# scope that leaves the webhook out still renders without it.

RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "${RENDER_DIR}"' EXIT

render() {
  local out="$1"
  shift
  helm template "${HELM_RELEASE}" "${HELM_CHART_PATH}" --namespace "${ISTIO_NAMESPACE}" "$@" > "${RENDER_DIR}/${out}.yaml"
}

query() {
  yq -r "select(.kind == \"MutatingWebhookConfiguration\") | $2" "${RENDER_DIR}/$1.yaml"
}

expect() {
  local what="$1" got="$2" want="$3"
  [[ "${got}" == "${want}" ]] || fail "${what}: expected '${want}', got '${got}'"
}

render default
expect "enforcer label" "$(query default '.metadata.labels["admissions.enforcer/disabled"]')" "true"
expect "enforcer label is a string" "$(query default '.metadata.labels["admissions.enforcer/disabled"] | tag')" "!!str"
expect "upstream label kept" "$(query default '.metadata.labels.app')" "sidecar-injector"

render namespace-scope --set global.resourceScope=namespace
expect "webhooks with resourceScope=namespace" "$(query namespace-scope '.kind' | grep -c . || true)" "0"

echo "All istiod-webhook-labels checks passed"
