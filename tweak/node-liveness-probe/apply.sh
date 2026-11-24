#!/usr/bin/env bash
# Adds a livenessProbe to the DaemonSets of the cni and ztunnel subcharts:
#   - wrap the daemonset.yaml that node-inotify left in place in a define of its own, so
#     the replacement can render it and parse the output, not patch it
#   - delete the original, which would otherwise render a second DaemonSet
#   - copy the replacement daemonset.yaml, keeping the upstream name and render order
# This runs after tweak/node-inotify, which has already replaced daemonset.yaml. Its define
# is named qubership.<chart>-daemonset-upstream, which is why the wrapper here has a
# different name. @CHART@ becomes the chart name, as in node-inotify.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHARTS_DIR="${1:?usage: apply.sh <charts-dir>}"

for chart in cni ztunnel; do
  TPL_DIR="${CHARTS_DIR}/${chart}/templates"
  if ! grep -q "qubership.${chart}-daemonset-upstream" "${TPL_DIR}/daemonset.yaml"; then
    echo "node-liveness-probe: ${TPL_DIR}/daemonset.yaml is not the node-inotify template; tweak/node-inotify must run first" >&2
    exit 1
  fi
  {
    echo "{{- define \"qubership.${chart}-daemonset-probe-upstream\" -}}"
    cat "${TPL_DIR}/daemonset.yaml"
    echo '{{- end -}}'
  } > "${TPL_DIR}/_daemonset-probe-upstream.tpl"
  rm "${TPL_DIR}/daemonset.yaml"
  sed "s/@CHART@/${chart}/g" "${SCRIPT_DIR}/daemonset.yaml" > "${TPL_DIR}/daemonset.yaml"
done
