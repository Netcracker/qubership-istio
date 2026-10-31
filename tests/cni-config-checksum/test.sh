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
# The render checks use excludeNamespaces, the setting the defect was about, and one key
# of cni.env. The live part uses a key of its own rather than a real setting: the agents
# ignore an environment variable they do not know, while EXCLUDE_NAMESPACES or a REPAIR_*
# value changed mid-suite would move the node under the tests that follow.
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
# excludeNamespaces is the setting the defect was about: it reaches the ConfigMap as
# EXCLUDE_NAMESPACES, and here only as a render flag, so no node sees it.
EXCLUDED="$(rendered_checksum --set 'cni.excludeNamespaces={custom-ns}')"
[ "${EXCLUDED}" != "${BEFORE_RENDERED}" ] ||
  fail "cni.excludeNamespaces={custom-ns} left the checksum at ${EXCLUDED}"

ENV_ONE="$(rendered_checksum --set "cni.env.${PROBE_KEY}=one")"
ENV_TWO="$(rendered_checksum --set "cni.env.${PROBE_KEY}=two")"
[ "${ENV_ONE}" != "${BEFORE_RENDERED}" ] ||
  fail "cni.env.${PROBE_KEY} does not reach istio-cni-config, so this probe proves nothing:
check whether the cni subchart still takes cni.env, and pick a value the ConfigMap does carry"
[ "${ENV_ONE}" != "${ENV_TWO}" ] ||
  fail "both values of cni.env.${PROBE_KEY} give the same checksum ${ENV_ONE}"

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
[ "${AFTER_LIVE}" == "${ENV_ONE}" ] ||
  fail "the installed checksum is ${AFTER_LIVE}, expected ${ENV_ONE}"
[ "${AFTER_REVISION}" != "${BEFORE_REVISION}" ] ||
  fail "${DS} kept revision ${BEFORE_REVISION}: the agents were not restarted by the change"
# The same ConfigMap the annotation was computed from.
kubectl -n "${ISTIO_NAMESPACE}" get configmap istio-cni-config \
  -o jsonpath="{.data.${PROBE_KEY}}" | grep -q "one" ||
  fail "istio-cni-config does not carry ${PROBE_KEY}=one"
echo "OK: the agents restarted on the config change, without rollout restart"
echo "::endgroup::"

echo "::group::the same configuration again rolls nothing"
# The value is already the installed one, so the ConfigMap does not change and neither may
# the DaemonSet. This is the other half of the annotation: it depends on the content, not
# on the number of upgrades.
upgrade_and_wait --set "cni.env.${PROBE_KEY}=one"
[ "$(live_checksum)" == "${AFTER_LIVE}" ] ||
  fail "an unchanged configuration changed the checksum to $(live_checksum)"
[ "$(live_revision)" == "${AFTER_REVISION}" ] ||
  fail "an unchanged configuration rolled ${DS} to $(live_revision)"
echo "OK: no restart without a configuration change"
echo "::endgroup::"

echo "::group::the next change rolls them again"
# helm --set cannot delete a key, so the suite ends with the probe key holding a second
# value rather than gone. That is harmless: it reaches the container as an environment
# variable the agents do not read, and the next upgrade of the release renders the
# ConfigMap without it.
upgrade_and_wait --set "cni.env.${PROBE_KEY}=two"
SECOND_LIVE="$(live_checksum)"
SECOND_REVISION="$(live_revision)"
[ "${SECOND_LIVE}" == "${ENV_TWO}" ] ||
  fail "the installed checksum after the second value is ${SECOND_LIVE}, expected ${ENV_TWO}"
[ "${SECOND_REVISION}" != "${AFTER_REVISION}" ] ||
  fail "${DS} kept revision ${AFTER_REVISION} when the value moved again"
echo "OK: the checksum follows the content on every change"
echo "::endgroup::"

echo "::group::the value is taken back out"
# helm cannot delete a key through --set except by nulling it, so what has to come back is
# the ConfigMap as the same flags render it, and the assertion is against that render rather
# than against a remembered checksum.
upgrade_and_wait --set "cni.env.${PROBE_KEY}=null"
WANT_REMOVED="$(rendered_checksum --set "cni.env.${PROBE_KEY}=null")"
GOT_REMOVED="$(live_checksum)"
[ "${GOT_REMOVED}" == "${WANT_REMOVED}" ] ||
  fail "the installed checksum after removing the value is ${GOT_REMOVED}, expected ${WANT_REMOVED}"
[ "$(live_revision)" != "${SECOND_REVISION}" ] ||
  fail "${DS} kept revision ${SECOND_REVISION} when the value was taken out"
echo "OK: the release carries no probe value left behind"
echo "::endgroup::"
