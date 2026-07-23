#!/usr/bin/env bash
# Injects the custom-registry template into every subchart package.
# zzzz prefix ensures the tweak template is loaded last, even after
# istio zzz_profile.yaml is processed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHARTS_DIR="${1:?usage: apply.sh <charts-dir>}"

for chart in cni istiod ztunnel; do
  cp "${SCRIPT_DIR}/zzzz_tweak.yaml" "${CHARTS_DIR}/${chart}/templates/"
done
