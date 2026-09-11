#!/usr/bin/env bash
set -eux

# Verifies the init container injected by tweak/node-inotify/.
#
# The environment decides nothing here. A runner ships whatever inotify limits it ships,
# an earlier install in the same job may have raised them already, and the two DaemonSets
# race for whichever runs first, so pinning a starting value or a branch would be pinning
# the runner rather than the code. The test creates the condition it checks: it reads what
# the node holds, asks for one more, and requires the container to write it.
#
# Nothing is ever lowered. The node ends one above where it started, which is why no
# cleanup is needed and why the tests that follow are unaffected.

INIT_NAME=node-inotify-tuning
WANT_INSTANCES=8192
WANT_WATCHES=65536
INSTANCES_FILE=/host-inotify/max_user_instances
WATCHES_FILE=/host-inotify/max_user_watches

echo "::group::init container is present in both DaemonSets"
for ds in istio-cni-node ztunnel; do
  kubectl get daemonset "${ds}" -n "${ISTIO_NAMESPACE}" \
    -o jsonpath="{.spec.template.spec.initContainers[?(@.name=='${INIT_NAME}')].name}" |
    grep -q "${INIT_NAME}" || fail "${ds}: no ${INIT_NAME} init container"
  kubectl rollout status "daemonset/${ds}" -n "${ISTIO_NAMESPACE}" --timeout=180s
done
echo "::endgroup::"

IMAGE=$(kubectl get daemonset ztunnel -n "${ISTIO_NAMESPACE}" \
  -o jsonpath="{.spec.template.spec.initContainers[?(@.name=='${INIT_NAME}')].image}")
NODE=$(kubectl get pods -n "${ISTIO_NAMESPACE}" -l app=ztunnel \
  -o jsonpath='{.items[0].spec.nodeName}')

# Both limits as the node itself reports them, read from a throwaway pod pinned to that
# node. Prints two lines: instances, then watches.
node_limits() {
  local name="node-inotify-check-$1"
  kubectl delete pod "${name}" --ignore-not-found >/dev/null
  kubectl run "${name}" --restart=Never --image="${IMAGE}" \
    --overrides="{\"spec\":{\"nodeName\":\"${NODE}\",\"containers\":[{\"name\":\"check\",\"image\":\"${IMAGE}\",\"imagePullPolicy\":\"IfNotPresent\",\"command\":[\"/bin/sh\",\"-c\",\"cat /proc/sys/fs/inotify/max_user_instances /proc/sys/fs/inotify/max_user_watches\"],\"securityContext\":{\"runAsUser\":0}}]}}" >/dev/null
  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${name}" --timeout=120s >/dev/null
  kubectl logs "${name}"
  kubectl delete pod "${name}" --wait=false >/dev/null
}

# The init log of the pod currently running for a DaemonSet, by its own label.
init_log() {
  local selector=$1 pod
  # Newest first: right after a rollout the previous pod can still be listed.
  pod=$(kubectl get pods -n "${ISTIO_NAMESPACE}" -l "${selector}" \
    --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')
  kubectl logs "${pod}" -n "${ISTIO_NAMESPACE}" -c "${INIT_NAME}"
}

echo "::group::the node is at or above the chart's targets"
BEFORE=$(node_limits before)
echo "${BEFORE}"
CUR_INSTANCES=$(echo "${BEFORE}" | sed -n 1p)
CUR_WATCHES=$(echo "${BEFORE}" | sed -n 2p)

[ "${CUR_INSTANCES}" -ge "${WANT_INSTANCES}" ] ||
  fail "the node reports max_user_instances=${CUR_INSTANCES}, expected at least ${WANT_INSTANCES}"
[ "${CUR_WATCHES}" -ge "${WANT_WATCHES}" ] ||
  fail "the node reports max_user_watches=${CUR_WATCHES}, expected at least ${WANT_WATCHES}"
echo "::endgroup::"

echo "::group::the raise branch runs, and the write reaches the node"
# One above what the node holds, so the container has no choice but to take the raise
# branch. This also proves the two values travel from global.nodeTuning into the command.
NEW_INSTANCES=$((CUR_INSTANCES + 1))
NEW_WATCHES=$((CUR_WATCHES + 1))

helm upgrade "${HELM_RELEASE}" "${HELM_CHART_PATH}" \
  --namespace "${ISTIO_NAMESPACE}" \
  --timeout 3m \
  --wait \
  --reuse-values \
  --set global.nodeTuning.inotify.maxUserInstances="${NEW_INSTANCES}" \
  --set global.nodeTuning.inotify.maxUserWatches="${NEW_WATCHES}"

for ds in istio-cni-node ztunnel; do
  kubectl rollout status "daemonset/${ds}" -n "${ISTIO_NAMESPACE}" --timeout=180s
done

# Whichever DaemonSet's init ran first did the raise and the other found the value already
# there, so the transition is asserted across the pair rather than on one of them.
LOGS="$(init_log k8s-app=istio-cni-node)
$(init_log app=ztunnel)"
echo "${LOGS}"

echo "${LOGS}" | grep -q "${INSTANCES_FILE}: ${CUR_INSTANCES} -> ${NEW_INSTANCES}" ||
  fail "neither DaemonSet reported raising max_user_instances to ${NEW_INSTANCES}"
echo "${LOGS}" | grep -q "${WATCHES_FILE}: ${CUR_WATCHES} -> ${NEW_WATCHES}" ||
  fail "neither DaemonSet reported raising max_user_watches to ${NEW_WATCHES}"

AFTER=$(node_limits after)
echo "${AFTER}"
[ "$(echo "${AFTER}" | sed -n 1p)" -eq "${NEW_INSTANCES}" ] ||
  fail "the log claims max_user_instances=${NEW_INSTANCES} but the node disagrees"
[ "$(echo "${AFTER}" | sed -n 2p)" -eq "${NEW_WATCHES}" ] ||
  fail "the log claims max_user_watches=${NEW_WATCHES} but the node disagrees"
echo "::endgroup::"

echo "::group::a value already at the target is left alone"
# The node now holds exactly what the DaemonSet asks for, so this restart can only take
# the other branch. No race to lose: nothing else moves the value in between.
kubectl rollout restart daemonset/ztunnel -n "${ISTIO_NAMESPACE}"
kubectl rollout status daemonset/ztunnel -n "${ISTIO_NAMESPACE}" --timeout=180s

KEPT=$(init_log app=ztunnel)
echo "${KEPT}"
echo "${KEPT}" | grep -q "${INSTANCES_FILE}: ${NEW_INSTANCES}, kept" ||
  fail "max_user_instances was not kept at ${NEW_INSTANCES}"
echo "${KEPT}" | grep -q "${WATCHES_FILE}: ${NEW_WATCHES}, kept" ||
  fail "max_user_watches was not kept at ${NEW_WATCHES}"
echo "::endgroup::"
