#!/usr/bin/env bash
set -eux

# Verifies the init container injected by tweak/node-inotify/. Both halves of the rule are
# checked: a limit below the target is raised, one already above it is left alone.
#
# Neither the node's factory values nor the branch taken is pinned. A runner ships what it
# ships - kind has been seen with 524288 and with 655360 watches - and an earlier install in
# the same job may already have raised the instances, so the second pod reports "kept".

INIT_NAME=node-inotify-tuning
WANT_INSTANCES=8192
WANT_WATCHES=65536

echo "::group::init container is present in both DaemonSets"
for ds in istio-cni-node ztunnel; do
  kubectl get daemonset "${ds}" -n "${ISTIO_NAMESPACE}" \
    -o jsonpath="{.spec.template.spec.initContainers[?(@.name=='${INIT_NAME}')].name}" |
    grep -q "${INIT_NAME}" || fail "${ds}: no ${INIT_NAME} init container"
  kubectl rollout status "daemonset/${ds}" -n "${ISTIO_NAMESPACE}" --timeout=180s
done
echo "::endgroup::"

echo "::group::the limits it reports"
POD=$(kubectl get pods -n "${ISTIO_NAMESPACE}" -l app=ztunnel -o jsonpath='{.items[0].metadata.name}')
LOG=$(kubectl logs "${POD}" -n "${ISTIO_NAMESPACE}" -c "${INIT_NAME}")
echo "${LOG}"

# Either branch is a pass. The space belongs to the first alternative alone: the second reads
# "8192, kept", with no space before the comma.
echo "${LOG}" | grep -qE "max_user_instances: [0-9]+( -> ${WANT_INSTANCES}|, kept)" ||
  fail "no verdict for max_user_instances in the init container log"

# Only-upwards, checked against what the node actually had rather than a pinned value: "kept"
# has to mean it was already at or above the target, a raise that it was below.
LINE=$(echo "${LOG}" | grep -m1 max_user_watches:)
CUR=$(echo "${LINE}" | sed -E 's/.*max_user_watches: ([0-9]+).*/\1/')
case "${LINE}" in
  *", kept")
    [ "${CUR}" -ge "${WANT_WATCHES}" ] ||
      fail "watches kept at ${CUR}, below the target ${WANT_WATCHES} - only-upwards is broken" ;;
  *"-> ${WANT_WATCHES}")
    [ "${CUR}" -lt "${WANT_WATCHES}" ] ||
      fail "watches raised from ${CUR}, already at or above ${WANT_WATCHES}" ;;
  *)
    fail "no verdict for max_user_watches in the init container log" ;;
esac
echo "::endgroup::"

echo "::group::the value the node actually kept"
IMAGE=$(kubectl get daemonset ztunnel -n "${ISTIO_NAMESPACE}" \
  -o jsonpath="{.spec.template.spec.initContainers[?(@.name=='${INIT_NAME}')].image}")
NODE=$(kubectl get pod "${POD}" -n "${ISTIO_NAMESPACE}" -o jsonpath='{.spec.nodeName}')

kubectl run node-inotify-check --restart=Never --image="${IMAGE}" \
  --overrides="{\"spec\":{\"nodeName\":\"${NODE}\",\"containers\":[{\"name\":\"check\",\"image\":\"${IMAGE}\",\"imagePullPolicy\":\"IfNotPresent\",\"command\":[\"/bin/sh\",\"-c\",\"cat /proc/sys/fs/inotify/max_user_instances\"],\"securityContext\":{\"runAsUser\":0}}]}}" >/dev/null

kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/node-inotify-check --timeout=120s
ON_NODE=$(kubectl logs node-inotify-check | tr -d '[:space:]')
kubectl delete pod node-inotify-check --wait=false

[ "${ON_NODE}" -ge "${WANT_INSTANCES}" ] ||
  fail "the node reports max_user_instances=${ON_NODE}, expected at least ${WANT_INSTANCES}"
echo "::endgroup::"
