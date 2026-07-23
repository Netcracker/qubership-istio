#!/usr/bin/env bash
# Narrows istiod webhook RBAC:
#   - wrap upstream ClusterRole as a partial and subtract broad webhook rules
#   - inject the resourceNames-scoped istiod-webhook-rbac.yaml
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHARTS_DIR="${1:?usage: apply.sh <charts-dir>}"
TPL_DIR="${CHARTS_DIR}/istiod/templates"

{
  echo '{{- define "qubership.istiod-clusterrole-upstream" -}}'
  cat "${TPL_DIR}/clusterrole.yaml"
  echo '{{- end -}}'
} > "${TPL_DIR}/_clusterrole-upstream.tpl"
rm "${TPL_DIR}/clusterrole.yaml"
cp "${SCRIPT_DIR}/istiod-clusterrole.yaml" "${TPL_DIR}/clusterrole.yaml"
cp "${SCRIPT_DIR}/istiod-webhook-rbac.yaml" "${TPL_DIR}/"
