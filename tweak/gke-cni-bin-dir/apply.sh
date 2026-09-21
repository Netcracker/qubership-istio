#!/usr/bin/env bash
# Adds the gke CNI binary directory template to the cni subchart.
# Helm renders templates in reverse lexical order, so the zzx prefix places this one after
# zzz_profile.yaml and zzy_descope_legacy.yaml, which blank cniBinDir for gke, and before
# daemonset.yaml, which reads it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHARTS_DIR="${1:?usage: apply.sh <charts-dir>}"

cp "${SCRIPT_DIR}/zzx_gke_cni_bin_dir.yaml" "${CHARTS_DIR}/cni/templates/"
