#!/usr/bin/env bash
# Adds serviceLabels to the istiod Service, which the upstream chart has no value for:
#   - wrap upstream service.yaml in a define, so its output can be parsed, not patched
#   - delete the original, which would otherwise render a second Service
#   - copy the replacement service.yaml, keeping the upstream name and render order
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHARTS_DIR="${1:?usage: apply.sh <charts-dir>}"
TPL_DIR="${CHARTS_DIR}/istiod/templates"

{
  echo '{{- define "qubership.istiod-service-upstream" -}}'
  cat "${TPL_DIR}/service.yaml"
  echo '{{- end -}}'
} > "${TPL_DIR}/_service-upstream.tpl"
rm "${TPL_DIR}/service.yaml"
cp "${SCRIPT_DIR}/service.yaml" "${TPL_DIR}/service.yaml"
