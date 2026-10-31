#!/usr/bin/env bash
set -eux

# Verifies the istio-cni-config checksum injected by tweak/cni-config-checksum/.
#
# The install-cni container gets its whole configuration from the istio-cni-config
# ConfigMap through envFrom, and reads it when it starts. Without something in the pod
# template that depends on that ConfigMap, a change to cni.env or cni.excludeNamespaces
# reaches the ConfigMap and stays unread: Helm sees an unchanged pod template and
# restarts nothing, so every node keeps what the previous run of the agents wrote.
#
# The test uses a key of its own rather than a real setting: the agents ignore an
# environment variable they do not know, while EXCLUDE_NAMESPACES or a REPAIR_* value
# changed mid-suite would move the node under the tests that follow.
#
# Nothing is left behind: the key is removed at the end, and the checksum is required to
# come back to the value it had before the test started.

DS=istio-cni-node
ANNOTATION=qubership.istio/istio-cni-config-checksum
PROBE_KEY=CNI_CONFIG_CHECKSUM_PROBE
RENDER_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "${RENDER_DIR}"
}
trap cleanup EXIT

# The checksum the chart renders, with extra helm flags.
rendered_checksum() {
  helm template "${HELM_RELEASE}" "${HELM_CHART_PATH}" --namespace "${ISTIO_NAMESPACE}" \
    --set MONITORING_ENABLED=false "$@" > "${RENDER_DIR}/chart.yaml"
  yq e -N "select(.kind == \"DaemonSet\" and .metadata.name == \"${DS}\")
            | .spec.template.metadata.annotations[\"${ANNOTATION}\"]" "${RENDER_DIR}/chart.yaml"
}

live_checksum() {
  kubectl -n "${ISTIO_NAMESPACE}" get daemonset "${DS}" \
    -o jsonpath="{.spec.template.metadata.annotations['${ANNOTATION}']}"
}

live_revision() {
  kubectl -n "${ISTIO_NAMESPACE}" get daemonset "${DS}" -o jsonpath='{.status.updateRevision}'
}

# Upgrade, and require the DaemonSet to roll on its own: nothing here runs rollout restart.
upgrade_and_wait() {
  helm upgrade "${HELM_RELEASE}" "${HELM_CHART_PATH}" \
    --namespace "${ISTIO_NAMESPACE}" \
    --timeout 3m \
    --wait \
    --reuse-values \
    "$@"
  kubectl -n "${ISTIO_NAMESPACE}" rollout status "daemonset/${DS}" --timeout=180s
}

echo "::group::the rendered pod template carries the checksum"
BEFORE_RENDERED="$(rendered_checksum)"
[ -n "${BEFORE_RENDERED}" ] && [ "${BEFORE_RENDERED}" != "null" ] ||
  fail "the DaemonSet template has no ${ANNOTATION} annotation"
echo "checksum: ${BEFORE_RENDERED}"
echo "::endgroup::"

echo "::group::a value in the ConfigMap moves it, a value outside it does not"
FIRST="$(rendered_checksum --set "cni.env.${PROBE_KEY}=one")"
SECOND="$(rendered_checksum --set "cni.env.${PROBE_KEY}=two")"
[ "${FIRST}" != "${BEFORE_RENDERED}" ] ||
  fail "cni.env.${PROBE_KEY}=one left the checksum at ${FIRST}"
[ "${FIRST}" != "${SECOND}" ] ||
  fail "both values of cni.env.${PROBE_KEY} give the same checksum ${FIRST}"
# The checksum is of the ConfigMap, not of the whole release: a value that reaches neither
# it nor the DaemonSet must not restart the agents.
UNCHANGED="$(rendered_checksum --set cni.resources.limits.memory=300Mi)"
[ "${UNCHANGED}" == "${BEFORE_RENDERED}" ] ||
  fail "cni.resources.limits.memory changed the checksum to ${UNCHANGED}"
echo "OK: one checksum per ConfigMap content, and nothing else moves it"
echo "::endgroup::"

echo "::group::an installed release rolls on a configuration change alone"
BEFORE_LIVE="$(live_checksum)"
BEFORE_REVISION="$(live_revision)"
echo "live checksum: ${BEFORE_LIVE}, revision: ${BEFORE_REVISION}"

upgrade_and_wait --set "cni.env.${PROBE_KEY}=one"

AFTER_LIVE="$(live_checksum)"
AFTER_REVISION="$(live_revision)"
echo "live checksum: ${AFTER_LIVE}, revision: ${AFTER_REVISION}"
[ "${AFTER_LIVE}" == "${FIRST}" ] ||
  fail "the installed checksum is ${AFTER_LIVE}, expected ${FIRST}"
[ "${AFTER_REVISION}" != "${BEFORE_REVISION}" ] ||
  fail "${DS} kept revision ${BEFORE_REVISION}: the agents were not restarted by the change"
# The same ConfigMap the annotation was computed from.
kubectl -n "${ISTIO_NAMESPACE}" get configmap istio-cni-config \
  -o jsonpath="{.data.${PROBE_KEY}}" | grep -q "one" ||
  fail "istio-cni-config does not carry ${PROBE_KEY}=one"
echo "OK: the agents restarted on the config change, without rollout restart"
echo "::endgroup::"

echo "::group::removing the value rolls them back, and the checksum returns"
upgrade_and_wait --set "cni.env.${PROBE_KEY}=null"
RESTORED="$(live_checksum)"
[ "${RESTORED}" == "${BEFORE_LIVE}" ] ||
  fail "the checksum after removing the value is ${RESTORED}, expected ${BEFORE_LIVE}"
[ "$(live_revision)" != "${AFTER_REVISION}" ] ||
  fail "${DS} kept revision ${AFTER_REVISION} after the value was removed"
echo "OK: the release is back where it started"
echo "::endgroup::"
