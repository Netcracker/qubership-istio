#!/usr/bin/env bash
set -eux

# Verifies the node inotify tuning injected by tweak/node-inotify/ on a live cluster.
#
# kind is the right place for this test rather than a simulation of it: its nodes ship
# the kernel default fs.inotify.max_user_instances=128, exactly the value the agents
# fail on, and fs.inotify.max_user_watches=524288, which is well above the 65536 this
# chart asks for. So one install exercises both halves of the rule - raise the limit
# that is too low, and leave alone the one that is already higher.

INIT_NAME=node-inotify-tuning
WANT_INSTANCES=8192

echo "::group::init container is present in both DaemonSets"
for ds in istio-cni-node ztunnel; do
  kubectl get daemonset "${ds}" -n "${ISTIO_NAMESPACE}" \
    -o jsonpath="{.spec.template.spec.initContainers[?(@.name=='${INIT_NAME}')].name}" |
    grep -q "${INIT_NAME}" || fail "${ds}: no ${INIT_NAME} init container in the DaemonSet"
  kubectl rollout status "daemonset/${ds}" -n "${ISTIO_NAMESPACE}" --timeout=180s
done
echo "::endgroup::"

echo "::group::init container raised the instance limit and left the watch limit alone"
POD=$(kubectl get pods -n "${ISTIO_NAMESPACE}" -l app=ztunnel -o jsonpath='{.items[0].metadata.name}')
LOG=$(kubectl logs "${POD}" -n "${ISTIO_NAMESPACE}" -c "${INIT_NAME}")
echo "${LOG}"

# Either the init container raised the limit (a fresh node ships the kernel default
# of 128) or a previous run already did. Both are correct; what must never happen is
# the line missing altogether, which means the container did not reach the file.
echo "${LOG}" | grep -qE "max_user_instances: [0-9]+ (-> ${WANT_INSTANCES}|, already at or above ${WANT_INSTANCES})" ||
  fail "the instance limit did not reach ${WANT_INSTANCES}; log above"

# The rule that protects a node someone else already tuned: kind ships 524288 watches,
# and the chart asks for 65536, so this line proves the write is skipped rather than
# applied downwards. A regression here silently divides a node's watch budget by eight.
echo "${LOG}" | grep -q "max_user_watches: 524288, already at or above" ||
  fail "the watch limit was not left alone - only-upwards is broken; log above"
echo "::endgroup::"

echo "::group::the value is actually set on the node"
# Read it back through a pod rather than trusting the log: the init container reports
# what it wrote, this reports what the kernel kept. The image is the one the init
# container already ran, so it is on the node and needs no pull.
IMAGE=$(kubectl get daemonset ztunnel -n "${ISTIO_NAMESPACE}" \
  -o jsonpath="{.spec.template.spec.initContainers[?(@.name=='${INIT_NAME}')].image}")
NODE=$(kubectl get pod "${POD}" -n "${ISTIO_NAMESPACE}" -o jsonpath='{.spec.nodeName}')

kubectl run node-inotify-check --restart=Never --image="${IMAGE}" \
  --overrides="$(cat <<JSON
{"spec":{"nodeName":"${NODE}","containers":[{"name":"check","image":"${IMAGE}",
"imagePullPolicy":"IfNotPresent","command":["/bin/sh","-c",
"cat /proc/sys/fs/inotify/max_user_instances"],
"securityContext":{"runAsUser":0}}]}}
JSON
)" >/dev/null

kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/node-inotify-check --timeout=120s
ON_NODE=$(kubectl logs node-inotify-check | tr -d '[:space:]')
kubectl delete pod node-inotify-check --wait=false

[ "${ON_NODE}" -ge "${WANT_INSTANCES}" ] ||
  fail "the node reports max_user_instances=${ON_NODE}, expected at least ${WANT_INSTANCES}"
echo "node reports max_user_instances=${ON_NODE}"
echo "::endgroup::"
