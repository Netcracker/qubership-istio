#!/usr/bin/env bash
set -eux

# Verifies cni.excludeNamespaces, the list of namespaces whose pods the CNI
# plugin lets through before it asks the Kubernetes API:
#   - the chart renders kube-system and istio-system into it;
#   - the running agents picked the list up;
#   - on a node whose agent stopped while the DaemonSet still existed, leaving
#     the plugin behind with a token that no longer works, a pod in another
#     namespace fails with Unauthorized, while a pod in istio-system starts.
#     This is what lets the pre-install hook run, and the new DaemonSet repair
#     the node, after Istio was removed by deleting its pods before the
#     DaemonSet (for example, by deleting the namespace);
#   - the node recovers once an agent is back on it.

PROBE_IMAGE="curlimages/curl:8.5.0"
PROBE="cni-exclude-probe"
OTHER_NS="cni-exclude-probe"
PARK_LABEL="qubership-istio-test/cni-parked"
RENDER_DIR="$(mktemp -d)"

# Parks the agents with a nodeSelector that no node matches. An agent that stops
# while its DaemonSet exists leaves the plugin behind unless the DaemonSet's node
# affinity no longer matches the node: ShouldStopCleanup checks node affinity and
# ignores nodeSelector, see
# https://github.com/istio/istio/blob/1.30.4/cni/pkg/nodeagent/server.go#L155
# Parking by node affinity would make the agents remove the plugin, and the
# stale-plugin checks below would prove nothing.
park_agents() {
  kubectl -n "${ISTIO_NAMESPACE}" patch daemonset istio-cni-node --type merge \
    -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"${PARK_LABEL}\":\"true\"}}}}}"
}

# A merge patch merges maps, so the key has to be removed by an explicit null:
# re-sending the original selector would leave the parking key in place.
unpark_agents() {
  kubectl -n "${ISTIO_NAMESPACE}" patch daemonset istio-cni-node --type merge \
    -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"${PARK_LABEL}\":null}}}}}"
  kubectl -n "${ISTIO_NAMESPACE}" rollout status daemonset/istio-cni-node --timeout=180s
}

# Leave the agents on every node whatever happens: a node without its agent
# keeps failing every new pod for the rest of the suite.
cleanup() {
  unpark_agents || true
  kubectl -n "${ISTIO_NAMESPACE}" delete pod "${PROBE}" --ignore-not-found --wait=false || true
  kubectl delete namespace "${OTHER_NS}" --ignore-not-found --wait=false || true
  rm -rf "${RENDER_DIR}"
}
trap cleanup EXIT

run_probe() {
  kubectl -n "$1" run "${PROBE}" --image="${PROBE_IMAGE}" --restart=Never --command -- sleep 600
}

# --- 1. Rendered: both namespaces are excluded ---
helm template "${HELM_RELEASE}" "${HELM_CHART_PATH}" \
  --namespace "${ISTIO_NAMESPACE}" \
  --set MONITORING_ENABLED=false > "${RENDER_DIR}/chart.yaml"
EXCLUDED="$(yq e -N \
  'select(.kind == "ConfigMap" and .metadata.name == "istio-cni-config") | .data.EXCLUDE_NAMESPACES' \
  "${RENDER_DIR}/chart.yaml")"
if [ "${EXCLUDED}" != "kube-system,istio-system" ]; then
  fail "EXCLUDE_NAMESPACES is '${EXCLUDED}', expected 'kube-system,istio-system'"
fi
echo "OK: the chart excludes kube-system and istio-system"

# --- 2. Live: every agent started with the list ---
for pod in $(kubectl -n "${ISTIO_NAMESPACE}" get pods -l k8s-app=istio-cni-node -o name); do
  if ! kubectl -n "${ISTIO_NAMESPACE}" logs "${pod}" | grep -q "ExcludeNamespaces: kube-system,istio-system"; then
    fail "${pod} did not start with istio-system excluded"
  fi
done
echo "OK: the running agents exclude istio-system"

# --- 3. A node with a stale plugin ---
# Narrowing the selector deletes the agent pods while the DaemonSet stays, so
# each agent leaves the plugin on its node, and no agent comes back.
park_agents
kubectl -n "${ISTIO_NAMESPACE}" wait --for=delete pod -l k8s-app=istio-cni-node --timeout=180s
# The API server caches a successful token review for a few seconds, so the
# dead token keeps working briefly after the agent pod is gone.
sleep 20

kubectl create namespace "${OTHER_NS}"
run_probe "${OTHER_NS}"
POISONED=""
for _ in $(seq 1 24); do
  if kubectl -n "${OTHER_NS}" get events \
      --field-selector "involvedObject.name=${PROBE},reason=FailedCreatePodSandBox" \
      -o jsonpath='{.items[*].message}' | grep -q 'failed (add): Unauthorized'; then
    POISONED="yes"
    break
  fi
  sleep 5
done
if [ -z "${POISONED}" ]; then
  fail "a pod outside the excluded namespaces started without an agent, so the plugin was not left behind and the next check would prove nothing"
fi
echo "OK: without an agent, a pod in ${OTHER_NS} fails with Unauthorized"

run_probe "${ISTIO_NAMESPACE}"
if ! kubectl -n "${ISTIO_NAMESPACE}" wait "pod/${PROBE}" --for=condition=Ready --timeout=90s; then
  fail "a pod in ${ISTIO_NAMESPACE} did not start on a node with a stale plugin"
fi
echo "OK: a pod in ${ISTIO_NAMESPACE} starts on the same node"

# --- 4. The node recovers once an agent is back ---
unpark_agents
kubectl -n "${OTHER_NS}" delete pod "${PROBE}" --wait=true
run_probe "${OTHER_NS}"
if ! kubectl -n "${OTHER_NS}" wait "pod/${PROBE}" --for=condition=Ready --timeout=90s; then
  fail "a pod in ${OTHER_NS} did not start after the agents came back"
fi
echo "OK: the node recovers once an agent is back"
