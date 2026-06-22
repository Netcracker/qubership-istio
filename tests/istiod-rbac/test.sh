#!/usr/bin/env bash
set -eux

# Verifies the qubership RBAC narrowing applied by tweak/ on a live cluster:
#   - webhook write access scoped to istiod's own webhooks via resourceNames
#     (tweak/istiod-clusterrole.patch)
#   - cluster-wide secret read removed; replaced by namespaced Role/RoleBinding
#     in an explicit allow-list (tweak/secrets-reader-rbac.yaml)
# We assert effective permissions through SubjectAccessReview, not rendered YAML.

# istiod ServiceAccount name; "-<revision>" suffix is omitted in this distribution
# because revision is empty. Update here if the chart starts setting a revision.
SA="system:serviceaccount:${ISTIO_NAMESPACE}:istiod"
READER_SA="system:serviceaccount:${ISTIO_NAMESPACE}:istio-reader-service-account"

ALLOWED_NS=rbac-test-allowed
DENIED_NS=rbac-test-denied

cleanup() {
  # Restore the default (empty) allow-list so later tests in this leg are
  # unaffected, then drop the scratch namespaces.
  helm upgrade "${HELM_RELEASE}" "${HELM_CHART_PATH}" \
    --namespace "${ISTIO_NAMESPACE}" \
    --timeout 3m \
    --wait \
    --reuse-values \
    --set 'istiod.qubership.secretsNamespaces={}' || true
  kubectl delete namespace "${ALLOWED_NS}" --ignore-not-found
  kubectl delete namespace "${DENIED_NS}" --ignore-not-found
}
trap cleanup EXIT

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
# No name -> only the unrestricted rule would grant this; it was removed.
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

# ---------------------------------------------------------------------------
# 2. Secrets: namespaced read in istio-system (via the upstream Role "istiod",
#    NOT our opt-in Role), and no cluster-wide access.
# ---------------------------------------------------------------------------
assert_can    get secrets -n "${ISTIO_NAMESPACE}"
assert_cannot get secrets --all-namespaces
kubectl create namespace "${DENIED_NS}"
assert_cannot get secrets -n "${DENIED_NS}"

# With the default (empty) allow-list, our opt-in Role must not be created at all —
# istio-system access comes from the upstream Role, ambient core needs nothing more.
if kubectl get role -n "${ISTIO_NAMESPACE}" -l app.kubernetes.io/name=istiod \
     -o name 2>/dev/null | grep -q istiod-secrets-reader; then
  fail "qubership istiod-secrets-reader Role should not exist with empty secretsNamespaces"
fi
echo "OK: secret read is namespaced (upstream Role), no cluster-wide access, no opt-in Role by default"

# ---------------------------------------------------------------------------
# 3. secretsNamespaces allow-list extends namespaced read on upgrade.
# ---------------------------------------------------------------------------
kubectl create namespace "${ALLOWED_NS}"
# Before opting in, the allowed namespace must NOT be readable.
assert_cannot get secrets -n "${ALLOWED_NS}"

helm upgrade "${HELM_RELEASE}" "${HELM_CHART_PATH}" \
  --namespace "${ISTIO_NAMESPACE}" \
  --timeout 3m \
  --wait \
  --reuse-values \
  --set "istiod.qubership.secretsNamespaces={${ALLOWED_NS}}"

# RBAC propagation is fast but not instantaneous; poll briefly.
for i in $(seq 1 12); do
  can get secrets -n "${ALLOWED_NS}" && break
  echo "Waiting for secrets-reader Role in ${ALLOWED_NS} (attempt ${i}/12)..."
  sleep 5
done

assert_can    get secrets -n "${ALLOWED_NS}"
# A namespace not in the list stays denied.
assert_cannot get secrets -n "${DENIED_NS}"
# istio-system still works after the upgrade.
assert_can    get secrets -n "${ISTIO_NAMESPACE}"

echo "OK: secretsNamespaces allow-list grants namespaced read only where listed"

# ---------------------------------------------------------------------------
# 4. istio-reader-service-account: cluster-wide secret read stripped, but the
#    rest of its discovery access (endpoints/pods/...) is intact.
# ---------------------------------------------------------------------------
reader_can() {
  [ "$(kubectl auth can-i "$@" --as="${READER_SA}" 2>/dev/null)" = "yes" ]
}

if reader_can get secrets --all-namespaces; then
  fail "reader SA should NOT read secrets cluster-wide, but can"
fi
echo "OK: reader SA CANNOT read secrets cluster-wide"

if reader_can get secrets -n "${ISTIO_NAMESPACE}"; then
  fail "reader SA should NOT read secrets in ${ISTIO_NAMESPACE}, but can"
fi
echo "OK: reader SA CANNOT read secrets in ${ISTIO_NAMESPACE}"

# Sanity: the rest of the reader's cluster-wide discovery access must survive.
if reader_can list endpoints --all-namespaces; then
  echo "OK: reader SA retains cluster-wide endpoints read"
else
  fail "reader SA lost endpoints read — transform over-stripped the rule"
fi

echo "All istiod-rbac checks passed"
