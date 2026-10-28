#!/usr/bin/env bash
# Adds livenessProbe to the discovery container of istiod, which upstream gives a readiness
# probe only:
#   - wrap upstream deployment.yaml in a define, so its output can be parsed, not patched
#   - delete the original, which would otherwise render a second Deployment
#   - copy the replacement deployment.yaml, keeping the upstream name and render order
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHARTS_DIR="${1:?usage: apply.sh <charts-dir>}"
TPL_DIR="${CHARTS_DIR}/istiod/templates"

{
  echo '{{- define "qubership.istiod-deployment-upstream" -}}'
  cat "${TPL_DIR}/deployment.yaml"
  echo '{{- end -}}'
} > "${TPL_DIR}/_deployment-upstream.tpl"
rm "${TPL_DIR}/deployment.yaml"
cp "${SCRIPT_DIR}/deployment.yaml" "${TPL_DIR}/deployment.yaml"
