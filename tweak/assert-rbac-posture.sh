#!/usr/bin/env bash
# Asserts the RBAC posture of the tweaked chart's istiod ClusterRole:
#   1. the istiod ClusterRoles render as real, non-empty objects (a separator slip
#      in the transform can make them unparseable and silently unapplied at install);
#   2. webhook writes are narrowed — no rule grants update/patch on webhook configs
#      without resourceNames.
# Rendering and the transform's fail-guard are already exercised by `ct lint`; this
# adds the SEMANTIC checks lint cannot do. Run right after tweak.sh.
#
# Note: cluster-wide secrets read is intentionally NOT asserted against — istiod's
# Gateway API credential informer requires it (see tweak/istiod-clusterrole.yaml).
set -euo pipefail

CHART="${1:-helm-templates/qubership-istio}"

rendered=$(helm template qubership-istio "${CHART}" \
  --namespace istio-system \
  --set MONITORING_ENABLED=false)

# 1. Positive existence check.
missing=""
for role in istiod-clusterrole istiod-gateway-controller; do
  found=$(echo "${rendered}" | yq ea "
    select(.kind == \"ClusterRole\" and (.metadata.name | test(\"^${role}-\")) and (.rules | length > 0))
    | .metadata.name" | head -n1)
  [ -z "${found}" ] && missing="${missing} ${role}"
done
if [ -n "${missing}" ]; then
  echo "::error::expected istiod ClusterRole(s) missing or empty after transform:${missing}" >&2
  exit 1
fi

# 2. Webhook writes must be resourceNames-scoped (no unrestricted update/patch).
unscoped=$(echo "${rendered}" | yq ea '
  select(.kind == "ClusterRole" and (.metadata.name | test("^istiod-clusterrole-")))
  | .rules[]
  | select(
      ((.resources // []) | (contains(["mutatingwebhookconfigurations"]) or contains(["validatingwebhookconfigurations"])))
      and ((.verbs // []) | (contains(["update"]) or contains(["patch"])))
      and (has("resourceNames") | not)
    )
  | (.resources | join(","))')

if [ -n "${unscoped}" ]; then
  echo "::error::istiod-clusterrole grants unrestricted webhook write (no resourceNames): ${unscoped}" >&2
  exit 1
fi
echo "OK: istiod ClusterRoles present and non-empty; webhook writes are resourceNames-scoped"
