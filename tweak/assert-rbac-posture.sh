#!/usr/bin/env bash
# Asserts the RBAC security posture of the tweaked chart: no ClusterRole may grant
# cluster-wide secret read (both istiod-clusterrole and istio-reader-clusterrole must
# be narrowed). Rendering and the transform's fail-guards are already exercised by
# `ct lint`; this adds the SEMANTIC check lint cannot do. Run right after tweak.sh.
set -euo pipefail

CHART="${1:-helm-templates/qubership-istio}"

rendered=$(helm template qubership-istio "${CHART}" \
  --namespace istio-system \
  --set MONITORING_ENABLED=false \
  --set 'istiod.qubership.secretsNamespaces={rbac-smoke-ns}')

missing=""
for role in istiod-clusterrole istiod-gateway-controller istio-reader-clusterrole; do
  found=$(echo "${rendered}" | yq ea "
    select(.kind == \"ClusterRole\" and (.metadata.name | test(\"^${role}-\")) and (.rules | length > 0))
    | .metadata.name" | head -n1)
  [ -z "${found}" ] && missing="${missing} ${role}"
done
if [ -n "${missing}" ]; then
  echo "::error::expected istiod ClusterRole(s) missing or empty after transform:${missing}" >&2
  exit 1
fi

offenders=$(echo "${rendered}" | yq ea '
  select(.kind == "ClusterRole")
  | select([.rules[] | select(((.apiGroups // []) | contains([""])) and ((.resources // []) | contains(["secrets"])))] | length > 0)
  | .metadata.name')

if [ -n "${offenders}" ]; then
  echo "::error::ClusterRole(s) still grant cluster-wide secrets read: ${offenders}" >&2
  exit 1
fi
echo "OK: istiod ClusterRoles present and non-empty; none grant cluster-wide secrets"
