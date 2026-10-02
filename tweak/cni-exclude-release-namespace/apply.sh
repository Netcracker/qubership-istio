#!/usr/bin/env bash
# Adds the template that puts the release namespace into excludeNamespaces to the cni subchart.
# Helm renders templates in reverse lexical order, so the zzx prefix places this one after
# zzz_profile.yaml, which merges the user's list, and before configmap-cni.yaml, which reads it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHARTS_DIR="${1:?usage: apply.sh <charts-dir>}"

cp "${SCRIPT_DIR}/zzx_cni_exclude_release_namespace.yaml" "${CHARTS_DIR}/cni/templates/"
