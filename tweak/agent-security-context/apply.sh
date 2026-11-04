#!/usr/bin/env bash
# Lets the cni and ztunnel DaemonSets take a securityContext for their main container:
#   - wrap the current daemonset.yaml in a define, so its output can be parsed, not patched.
#     By now that file is the one tweak/node-inotify/ wrote, not the upstream one
#   - delete it, which would otherwise render a second DaemonSet
#   - copy the replacement daemonset.yaml, keeping the upstream name and render order
# @CHART@ becomes the chart name: the two charts must not share a template name.
# @CONTAINER@ becomes the main container the values are applied to.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHARTS_DIR="${1:?usage: apply.sh <charts-dir>}"

for chart in cni ztunnel; do
  case "${chart}" in
    cni) container=install-cni ;;
    ztunnel) container=istio-proxy ;;
  esac
  TPL_DIR="${CHARTS_DIR}/${chart}/templates"
  {
    echo "{{- define \"qubership.${chart}-daemonset-pre-security-context\" -}}"
    cat "${TPL_DIR}/daemonset.yaml"
    echo '{{- end -}}'
  } > "${TPL_DIR}/_daemonset-pre-security-context.tpl"
  rm "${TPL_DIR}/daemonset.yaml"
  sed -e "s/@CHART@/${chart}/g" -e "s/@CONTAINER@/${container}/g" \
    "${SCRIPT_DIR}/daemonset.yaml" > "${TPL_DIR}/daemonset.yaml"
done
