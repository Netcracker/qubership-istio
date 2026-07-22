#!/usr/bin/env bash
# Asserts the RBAC posture of the tweaked chart:
#   1. the istiod ClusterRoles render as real, non-empty objects (a separator slip
#      in the transform can make them unparseable and silently unapplied at install);
#   2. the broad webhook rules were subtracted from istiod-clusterrole;
#   3. no ClusterRole grants a webhook update/patch without resourceNames — i.e. the
#      only webhook writes come from the narrowed istiod-webhook-rbac role.
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

# 1. Positive existence check (the subtracted role, the passthrough role, and the
#    narrowed webhook role must all render).
missing=""
for role in istiod-clusterrole istiod-gateway-controller istiod-webhook-rbac; do
  found=$(echo "${rendered}" | yq ea "
    select(.kind == \"ClusterRole\" and (.metadata.name | test(\"^${role}-\")) and (.rules | length > 0))
    | .metadata.name" | head -n1)
  [ -z "${found}" ] && missing="${missing} ${role}"
done
if [ -n "${missing}" ]; then
  echo "::error::expected ClusterRole(s) missing or empty after tweak:${missing}" >&2
  exit 1
fi

# 2. istiod-clusterrole must no longer carry any webhook rule (they were subtracted).
leftover=$(echo "${rendered}" | yq ea '
  select(.kind == "ClusterRole" and (.metadata.name | test("^istiod-clusterrole-")))
  | .rules[]
  | select((.resources // []) | (contains(["mutatingwebhookconfigurations"]) or contains(["validatingwebhookconfigurations"])))
  | (.resources | join(","))')
if [ -n "${leftover}" ]; then
  echo "::error::istiod-clusterrole still carries webhook rules (subtract failed): ${leftover}" >&2
  exit 1
fi

# 3. No ClusterRole anywhere may grant a webhook update/patch without resourceNames.
unscoped=$(echo "${rendered}" | yq ea '
  select(.kind == "ClusterRole")
  | .rules[]
  | select(
      ((.resources // []) | (contains(["mutatingwebhookconfigurations"]) or contains(["validatingwebhookconfigurations"])))
      and ((.verbs // []) | (contains(["update"]) or contains(["patch"])))
      and (has("resourceNames") | not)
    )
  | (.resources | join(","))')
if [ -n "${unscoped}" ]; then
  echo "::error::a ClusterRole grants unrestricted webhook write (no resourceNames): ${unscoped}" >&2
  exit 1
fi
echo "OK: webhook rules subtracted from istiod-clusterrole; webhook writes are resourceNames-scoped"
