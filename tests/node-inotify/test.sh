#!/usr/bin/env bash
set -eux

# Verifies the init container injected by tweak/node-inotify/. kind is the right cluster for it:
# it ships the kernel default of 128 instances and 524288 watches, so one install covers both
# halves of the rule - raise the limit that is too low, leave the one that is already higher.

INIT_NAME=node-inotify-tuning
WANT_INSTANCES=8192

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

echo "${LOG}" | grep -qE "max_user_instances: [0-9]+ (-> ${WANT_INSTANCES}|, kept)" ||
  fail "the instance limit did not reach ${WANT_INSTANCES}"

# kind ships 524288 watches and the chart asks for 65536, so this line is what proves the write
# is skipped rather than applied downwards.
echo "${LOG}" | grep -q "max_user_watches: 524288, kept" ||
  fail "the watch limit was lowered - only-upwards is broken"
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
