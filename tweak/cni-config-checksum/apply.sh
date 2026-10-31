#!/usr/bin/env bash
# Adds a checksum of the istio-cni-config ConfigMap to the istio-cni-node pod template.
# Without it a change to the agents' configuration is written to the ConfigMap and left
# unread: the agents read it once, when they start, so the nodes keep what the previous
# run of them wrote until something else restarts them.
#   - wrap the tuned daemonset.yaml in a define, so its output can be parsed, not patched
#   - delete the original, which would otherwise render a second DaemonSet
#   - copy the replacement daemonset.yaml, keeping the upstream name and render order
# Run this after node-inotify: it wraps the file node-inotify leaves behind.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHARTS_DIR="${1:?usage: apply.sh <charts-dir>}"

TPL_DIR="${CHARTS_DIR}/cni/templates"
if [ ! -f "${TPL_DIR}/daemonset.yaml" ]; then
  echo "cni-config-checksum: ${TPL_DIR}/daemonset.yaml is missing; apply node-inotify first" >&2
  exit 1
fi

{
  echo '{{- define "qubership.cni-daemonset-tuned" -}}'
  cat "${TPL_DIR}/daemonset.yaml"
  echo '{{- end -}}'
} > "${TPL_DIR}/_daemonset-tuned.tpl"
rm "${TPL_DIR}/daemonset.yaml"
cp "${SCRIPT_DIR}/daemonset.yaml" "${TPL_DIR}/daemonset.yaml"
