#!/usr/bin/env bash
# Puts containerSecurityContext on the main container of the cni and ztunnel DaemonSets:
#   - wrap the current daemonset.yaml, the one tweak/node-inotify/ wrote, in a define
#   - delete it, which would otherwise render a second DaemonSet
#   - copy the replacement daemonset.yaml, which parses that render and sets the keys
# @CHART@ becomes the chart name, @CONTAINER@ the main container.
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
