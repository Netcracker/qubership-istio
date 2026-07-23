#!/usr/bin/env bash
set -eux

# Verifies the qubership RBAC narrowing applied by tweak/istiod-rbac/ on a live cluster:
#   - webhook write access is scoped to istiod's own webhooks via resourceNames
#     (tweak/istiod-rbac/istiod-clusterrole.yaml); list/watch stay cluster-wide;
# Assert effective permissions through SubjectAccessReview, not rendered YAML.

# istiod ServiceAccount name; "-<revision>" suffix is omitted in this distribution
# because revision is empty. Update here if the chart starts setting a revision.
SA="system:serviceaccount:${ISTIO_NAMESPACE}:istiod"

# can <args...> -> true if istiod SA is allowed the action, false otherwise.
can() {
  [ "$(kubectl auth can-i "$@" --as="${SA}" 2>/dev/null)" = "yes" ]
}

assert_can() {
  if can "$@"; then
    echo "OK: istiod CAN '$*'"
  else
    fail "istiod should be allowed '$*' but is not"
  fi
}

assert_cannot() {
  if can "$@"; then
    fail "istiod should NOT be allowed '$*' but is"
  else
    echo "OK: istiod CANNOT '$*'"
  fi
}

# ---------------------------------------------------------------------------
# 1. Webhooks: write verbs only on istiod's own webhook configs (resourceNames),
#    collection verbs (list/watch) remain cluster-wide.
# ---------------------------------------------------------------------------
INJECTOR="istio-sidecar-injector-${ISTIO_NAMESPACE}"
VALIDATOR="istio-validator-${ISTIO_NAMESPACE}"

assert_can    update "mutatingwebhookconfigurations/${INJECTOR}"
assert_can    list   mutatingwebhookconfigurations
assert_can    watch  mutatingwebhookconfigurations
# No name -> only an unrestricted rule would grant this; it was narrowed away.
assert_cannot update mutatingwebhookconfigurations
# A foreign webhook must not be writable.
assert_cannot update mutatingwebhookconfigurations/some-foreign-webhook

assert_can    update "validatingwebhookconfigurations/${VALIDATOR}"
# istiod's validation controller patches the runtime "istiod-default-validator"
# too; both names must be writable or istiod loops on a Forbidden error.
assert_can    update "validatingwebhookconfigurations/istiod-default-validator"
assert_can    list   validatingwebhookconfigurations
assert_cannot update validatingwebhookconfigurations
# patch was never granted for validating webhooks even by name.
assert_cannot patch  "validatingwebhookconfigurations/${VALIDATOR}"

echo "OK: webhook RBAC narrowed to istiod's own configurations"

echo "All istiod-rbac checks passed"
