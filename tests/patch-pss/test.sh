#!/usr/bin/env bash
set -eux

# Verifies the pre-deploy Pod Security Standards patch (templates/PatchPss.yaml):
#   - nothing is rendered while ENABLE_PRIVILEGED_PSS is off (the default);
#   - the rendered Job is PSS "restricted"-compliant and the Role is scoped to
#     this namespace by resourceNames;
#   - on a namespace that really enforces "restricted", the hook admits its own
#     pod and flips the label to privileged (the chicken-and-egg guarantee, and
#     the only check that cannot be made from rendered YAML);
#   - hook resources are cleaned up by hook-delete-policy;
#   - a second run is a no-op and still succeeds.

LABEL_KEY="pod-security.kubernetes.io/enforce"
RENDER_DIR="$(mktemp -d)"

read_label() {
  kubectl get namespace "${ISTIO_NAMESPACE}" \
    -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}'
}

ORIGINAL_LABEL="$(read_label)"

# Always hand the namespace back as we found it: a leftover enforce=restricted
# would make every later pod creation in istio-system fail.
cleanup() {
  if [ -z "${ORIGINAL_LABEL}" ]; then
    kubectl label namespace "${ISTIO_NAMESPACE}" "${LABEL_KEY}-" || true
  else
    kubectl label --overwrite namespace "${ISTIO_NAMESPACE}" "${LABEL_KEY}=${ORIGINAL_LABEL}" || true
  fi
  rm -rf "${RENDER_DIR}"
}
trap cleanup EXIT

# --- 1. Off by default: no patch-pss resources rendered ---
helm template "${HELM_RELEASE}" "${HELM_CHART_PATH}" \
  --namespace "${ISTIO_NAMESPACE}" \
  --set MONITORING_ENABLED=false > "${RENDER_DIR}/off.yaml"
if grep -q "istio-patch-pss" "${RENDER_DIR}/off.yaml"; then
  fail "patch-pss resources rendered although ENABLE_PRIVILEGED_PSS is off"
fi
echo "OK: no patch-pss resources rendered by default"

# --- 2. Rendered manifests: restricted-compliant Job, namespace-scoped Role ---
helm template "${HELM_RELEASE}" "${HELM_CHART_PATH}" \
  --namespace "${ISTIO_NAMESPACE}" \
  --set MONITORING_ENABLED=false \
  --set ENABLE_PRIVILEGED_PSS=true > "${RENDER_DIR}/on.yaml"

for kind in ServiceAccount Role RoleBinding Job; do
  if ! yq e -N "select(.kind == \"${kind}\" and .metadata.name == \"istio-patch-pss\")" \
      "${RENDER_DIR}/on.yaml" | grep -q .; then
    fail "${kind}/istio-patch-pss missing from the rendered chart"
  fi
done
echo "OK: all four patch-pss resources are rendered"

JOB="$(yq e -N 'select(.kind == "Job" and .metadata.name == "istio-patch-pss")' "${RENDER_DIR}/on.yaml")"
if [ "$(echo "${JOB}" | yq e '.spec.template.spec.securityContext.runAsNonRoot')" != "true" ]; then
  fail "patch-pss pod is not runAsNonRoot; it would be rejected by PSS restricted"
fi
if [ "$(echo "${JOB}" | yq e '.spec.template.spec.securityContext.runAsUser')" = "0" ]; then
  fail "patch-pss pod runAsUser must be non-zero"
fi
if [ "$(echo "${JOB}" | yq e '.spec.template.spec.securityContext.seccompProfile.type')" != "RuntimeDefault" ]; then
  fail "patch-pss pod seccompProfile must be RuntimeDefault"
fi
if [ "$(echo "${JOB}" | yq e '.spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation')" != "false" ]; then
  fail "patch-pss container must set allowPrivilegeEscalation=false"
fi
if [ "$(echo "${JOB}" | yq e '.spec.template.spec.containers[0].securityContext.capabilities.drop[0]')" != "ALL" ]; then
  fail "patch-pss container must drop ALL capabilities"
fi
echo "OK: rendered patch-pss Job satisfies PSS restricted"

ROLE_NS="$(yq e -N 'select(.kind == "Role" and .metadata.name == "istio-patch-pss")
  | .rules[0].resourceNames[0]' "${RENDER_DIR}/on.yaml")"
if [ "${ROLE_NS}" != "${ISTIO_NAMESPACE}" ]; then
  fail "Role resourceNames expected ${ISTIO_NAMESPACE}, got ${ROLE_NS}"
fi
echo "OK: Role is scoped to namespace ${ISTIO_NAMESPACE}"

# --- 3. Live: the hook relaxes a namespace that really enforces "restricted" ---
# PSA is evaluated at pod admission only, so labelling now cannot disturb the
# already-running istio pods; the pre-upgrade hook restores privileged before the
# upgrade applies any Istio manifest.
kubectl label --overwrite namespace "${ISTIO_NAMESPACE}" "${LABEL_KEY}=restricted"
if [ "$(read_label)" != "restricted" ]; then
  fail "failed to stage ${LABEL_KEY}=restricted"
fi

# --force-conflicts: istiod takes SSA ownership of webhook fields, so upgrades
# need it from the second one onwards (see templates/NOTES.txt).
helm upgrade "${HELM_RELEASE}" "${HELM_CHART_PATH}" \
  --namespace "${ISTIO_NAMESPACE}" \
  --timeout 3m \
  --wait \
  --force-conflicts \
  --reuse-values \
  --set ENABLE_PRIVILEGED_PSS=true

AFTER="$(read_label)"
if [ "${AFTER}" != "privileged" ]; then
  echo "ERROR: expected ${LABEL_KEY}=privileged after the hook, got '${AFTER}'"
  kubectl get namespace "${ISTIO_NAMESPACE}" -o yaml
  fail "patch-pss hook did not relabel the namespace"
fi
echo "OK: hook Job relabelled ${ISTIO_NAMESPACE} from restricted to privileged"

# --- 4. Hook resources removed on success (hook-delete-policy) ---
for res in job/istio-patch-pss \
           serviceaccount/istio-patch-pss \
           role.rbac.authorization.k8s.io/istio-patch-pss \
           rolebinding.rbac.authorization.k8s.io/istio-patch-pss; do
  if kubectl get "${res}" -n "${ISTIO_NAMESPACE}" >/dev/null 2>&1; then
    fail "${res} still exists; hook-delete-policy hook-succeeded did not apply"
  fi
done
echo "OK: hook resources cleaned up after success"

# --- 5. Idempotency: re-running with the label already correct still succeeds ---
helm upgrade "${HELM_RELEASE}" "${HELM_CHART_PATH}" \
  --namespace "${ISTIO_NAMESPACE}" \
  --timeout 3m \
  --wait \
  --force-conflicts \
  --reuse-values \
  --set ENABLE_PRIVILEGED_PSS=true
if [ "$(read_label)" != "privileged" ]; then
  fail "label changed on the idempotent re-run"
fi
echo "OK: second run is a no-op"

echo "All patch-pss checks passed"
