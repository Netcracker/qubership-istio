#!/usr/bin/env bash
# Adds the node inotify tuning init container to the cni and ztunnel DaemonSets:
#   - wrap the upstream DaemonSet template as a partial
#   - put a template in its place that renders the partial and injects the container
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHARTS_DIR="${1:?usage: apply.sh <charts-dir>}"

for chart in cni ztunnel; do
  TPL_DIR="${CHARTS_DIR}/${chart}/templates"
  {
    echo "{{- define \"qubership.${chart}-daemonset-upstream\" -}}"
    cat "${TPL_DIR}/daemonset.yaml"
    echo '{{- end -}}'
  } > "${TPL_DIR}/_daemonset-upstream.tpl"
  rm "${TPL_DIR}/daemonset.yaml"
  # Keeps the upstream file name so it keeps its place in Helm's reverse render order.
  sed "s/@CHART@/${chart}/g" "${SCRIPT_DIR}/daemonset.yaml" > "${TPL_DIR}/daemonset.yaml"
done
