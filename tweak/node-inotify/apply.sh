#!/usr/bin/env bash
# Adds the node inotify tuning init container to the cni and ztunnel DaemonSets:
#   - wrap upstream daemonset.yaml in a define, so its output can be parsed, not patched
#   - delete the original, which would otherwise render a second DaemonSet
#   - copy the init container spec
#   - copy the replacement daemonset.yaml, keeping the upstream name and render order
# @CHART@ becomes the chart name: the two charts must not share a template name.
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
  sed "s/@CHART@/${chart}/g" "${SCRIPT_DIR}/_node-inotify.tpl" > "${TPL_DIR}/_node-inotify.tpl"
  sed "s/@CHART@/${chart}/g" "${SCRIPT_DIR}/daemonset.yaml" > "${TPL_DIR}/daemonset.yaml"
done
