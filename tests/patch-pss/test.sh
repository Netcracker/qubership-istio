#!/usr/bin/env bash
set -eux

# Verifies the pre-deploy Pod Security Standards patch (templates/PatchPss.yaml):
#   - nothing is rendered while ENABLE_PRIVILEGED_PSS is off (the default);
#   - the rendered Job is PSS "restricted"-compliant and the Role is scoped to
#     this namespace by resourceNames;
#   - global.imagePullSecrets, an Istio-convention list of bare names, reaches the
#     ServiceAccount in the shape the core/v1 API accepts;
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
PREINSTALL_NS="patch-pss-preinstall"

cleanup() {
  kubectl delete namespace "${PREINSTALL_NS}" --ignore-not-found --wait=false || true
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

# --- 2a. imagePullSecrets: Istio passes bare names, the API wants objects ---
# global.imagePullSecrets is an Istio convention and holds plain strings, while
# ServiceAccount.imagePullSecrets is []LocalObjectReference. Emitting the list
# as-is renders valid YAML that the apiserver rejects at decode, so the shape is
# checked here and the decode itself by a server dry-run.
helm template "${HELM_RELEASE}" "${HELM_CHART_PATH}" \
  --namespace "${ISTIO_NAMESPACE}" \
  --set MONITORING_ENABLED=false \
  --set ENABLE_PRIVILEGED_PSS=true \
  --set "global.imagePullSecrets={first-secret,second-secret}" \
  --show-only templates/PatchPss.yaml > "${RENDER_DIR}/pull-secrets.yaml"

PULL_SECRET_NAMES="$(yq e -N \
  'select(.kind == "ServiceAccount") | .imagePullSecrets[].name' \
  "${RENDER_DIR}/pull-secrets.yaml" | tr '\n' ',')"
if [ "${PULL_SECRET_NAMES}" != "first-secret,second-secret," ]; then
  fail "expected imagePullSecrets named first-secret,second-secret, got '${PULL_SECRET_NAMES}'"
fi

kubectl apply --dry-run=server -f "${RENDER_DIR}/pull-secrets.yaml" \
  || fail "the apiserver refused the rendered patch-pss manifests"

# Unset stays unset: an empty imagePullSecrets list is rejected as well.
if grep -q "imagePullSecrets" "${RENDER_DIR}/on.yaml"; then
  fail "imagePullSecrets rendered although global.imagePullSecrets is not set"
fi
echo "OK: imagePullSecrets are named references, and absent when unset"

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

# --- 6. Install path: the Job is admitted by a namespace that enforced
#        "restricted" from the moment it was created ---
# Checks 3-5 exercise the pre-upgrade branch, where the namespace is relaxed
# again by an earlier release and the label is put back by hand. The install
# branch is the harder one and the one an air-gapped operator hits first: the
# namespace is born "restricted", nothing has run in it yet, and the hook has to
# get its own pod past the policy it exists to relax. Rendering the hook on its
# own keeps this to one namespace and does not disturb the release under test.
kubectl create namespace "${PREINSTALL_NS}"
kubectl label --overwrite namespace "${PREINSTALL_NS}" "${LABEL_KEY}=restricted"

helm template "${HELM_RELEASE}" "${HELM_CHART_PATH}" \
  --namespace "${PREINSTALL_NS}" \
  --set MONITORING_ENABLED=false \
  --set ENABLE_PRIVILEGED_PSS=true \
  --show-only templates/PatchPss.yaml > "${RENDER_DIR}/preinstall.yaml"

# Without --validate the apiserver still runs admission, which is the point here:
# a non-compliant pod template is rejected when the Job creates its pod.
kubectl apply -n "${PREINSTALL_NS}" -f "${RENDER_DIR}/preinstall.yaml"

if ! kubectl wait --for=condition=complete job/istio-patch-pss \
    -n "${PREINSTALL_NS}" --timeout=120s; then
  echo "--- Job ---"
  kubectl describe job/istio-patch-pss -n "${PREINSTALL_NS}" || true
  echo "--- pods ---"
  kubectl get pods -n "${PREINSTALL_NS}" -o wide || true
  echo "--- events ---"
  kubectl get events -n "${PREINSTALL_NS}" --sort-by=.lastTimestamp || true
  fail "patch-pss Job did not complete in a namespace that enforces restricted"
fi

PREINSTALL_LABEL="$(kubectl get namespace "${PREINSTALL_NS}" \
  -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')"
if [ "${PREINSTALL_LABEL}" != "privileged" ]; then
  fail "expected ${LABEL_KEY}=privileged on ${PREINSTALL_NS}, got '${PREINSTALL_LABEL}'"
fi
echo "OK: hook admitted itself into a restricted namespace and relabelled it on the install path"

kubectl delete namespace "${PREINSTALL_NS}" --wait=false

echo "All patch-pss checks passed"
