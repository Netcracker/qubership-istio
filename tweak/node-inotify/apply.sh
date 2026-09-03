#!/usr/bin/env bash
# Wraps the upstream cni and ztunnel DaemonSet templates as partials and puts a template in
# their place that renders the partial and injects the node inotify tuning init container.
set -euo pipefail

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
CHARTS_DIR="${1:?usage: apply.sh <charts-dir>}"

for chart in cni ztunnel; do
  TPL_DIR="${CHARTS_DIR}/${chart}/templates"
  { echo "{{- define \"qubership.${chart}-daemonset-upstream\" -}}"
    cat "${TPL_DIR}/daemonset.yaml"
    echo '{{- end -}}'; } > "${TPL_DIR}/_daemonset-upstream.tpl"
  # Reuses the upstream file name so it keeps its place in Helm's reverse render order.
  sed "s/@CHART@/${chart}/g" "${SCRIPT_DIR}/daemonset.yaml" > "${TPL_DIR}/daemonset.yaml"
done
