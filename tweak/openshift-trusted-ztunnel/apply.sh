#!/usr/bin/env bash
# Adds the openshift trusted ztunnel namespace template to the istiod subchart.
# Helm renders templates in reverse lexical order, so the zzzz prefix places this one before
# zzz_profile.yaml. That is the only point where a value the user set is still told apart from
# the platform profile, which sets trustedZtunnelNamespace for openshift.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHARTS_DIR="${1:?usage: apply.sh <charts-dir>}"

cp "${SCRIPT_DIR}/zzzz_openshift_trusted_ztunnel.yaml" "${CHARTS_DIR}/istiod/templates/"
