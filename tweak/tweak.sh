#!/usr/bin/env bash
# Orchestrates all chart tweaks: unpack subcharts, run each action, repack.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHARTS_DIR=./helm-templates/qubership-istio/charts

# 1. Unpack all subcharts.
for chart in cni istiod ztunnel; do
  tar -xzf "$(ls ${CHARTS_DIR}/${chart}-*.tgz)" -C "${CHARTS_DIR}"
done

# 2. Apply tweaks (one script per action folder).
bash "${SCRIPT_DIR}/custom-registry/apply.sh" "${CHARTS_DIR}"
bash "${SCRIPT_DIR}/istiod-rbac/apply.sh" "${CHARTS_DIR}"
bash "${SCRIPT_DIR}/node-inotify/apply.sh" "${CHARTS_DIR}"

# 3. Repack all subcharts.
for chart in cni istiod ztunnel; do
  tar -czf "$(ls ${CHARTS_DIR}/${chart}-*.tgz)" -C "${CHARTS_DIR}" "${chart}"
  rm -rf "${CHARTS_DIR}/${chart}"
done
