#!/usr/bin/env bash
# Adds the admissions.enforcer/disabled label to the istiod MutatingWebhookConfiguration.
# On AKS the admissions enforcer adds selectors to every webhook without it, so the webhook
# never matches the manifest and Argo CD reports it as OutOfSync.
set -euo pipefail

CHARTS_DIR="${1:?usage: apply.sh <charts-dir>}"

sed -i 's|^  labels:$|&\n    admissions.enforcer/disabled: "true"|' \
  "${CHARTS_DIR}/istiod/templates/mutatingwebhook.yaml"
