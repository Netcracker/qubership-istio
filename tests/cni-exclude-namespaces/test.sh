#!/usr/bin/env bash
set -eux

# Verifies cni.excludeNamespaces, the list of namespaces whose pods the CNI
# plugin lets through before it asks the Kubernetes API:
#   - the chart renders kube-system and the release namespace into it, and keeps
#     the release namespace in a list set in the values;
#   - the installed release carries the list;
#   - on a node whose agent stopped while the DaemonSet still existed, leaving
#     the plugin behind with a token that no longer works, a pod in another
#     namespace fails with Unauthorized, while a pod in istio-system starts.
#     This is what lets the pre-install hook run, and the new DaemonSet repair
#     the node, after Istio was removed by deleting its pods before the
#     DaemonSet (for example, by deleting the namespace);
#   - the node recovers once an agent is back on it.

# The probe only has to start. The pause image comes from registry.k8s.io, not
# Docker Hub, and the kind nodes already have it.
PROBE_IMAGE="registry.k8s.io/pause:3.10"
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
  kubectl -n "$1" run "${PROBE}" --image="${PROBE_IMAGE}" --restart=Never
}

# EXCLUDE_NAMESPACES of the istio-cni-config ConfigMap rendered with extra flags.
rendered_excluded() {
  helm template "${HELM_RELEASE}" "${HELM_CHART_PATH}" --set MONITORING_ENABLED=false "$@" \
    > "${RENDER_DIR}/chart.yaml"
  yq e -N 'select(.kind == "ConfigMap" and .metadata.name == "istio-cni-config") | .data.EXCLUDE_NAMESPACES' \
    "${RENDER_DIR}/chart.yaml"
}

expect_excluded() {
  local what="$1" want="$2"
  shift 2
  local got
  got="$(rendered_excluded "$@")"
  [ "${got}" == "${want}" ] || fail "${what}: EXCLUDE_NAMESPACES is '${got}', expected '${want}'"
}

# --- 1. Rendered: the release namespace is always excluded ---
expect_excluded "default list" "kube-system,${ISTIO_NAMESPACE}" --namespace "${ISTIO_NAMESPACE}"
expect_excluded "list set in the values" "custom-ns,${ISTIO_NAMESPACE}" \
  --namespace "${ISTIO_NAMESPACE}" --set 'cni.excludeNamespaces={custom-ns}'
expect_excluded "list that already has the release namespace" "kube-system,${ISTIO_NAMESPACE}" \
  --namespace "${ISTIO_NAMESPACE}" --set "cni.excludeNamespaces={kube-system,${ISTIO_NAMESPACE}}"
expect_excluded "another release namespace" "kube-system,other-mesh-ns" --namespace other-mesh-ns
echo "OK: the chart always excludes the release namespace"

# --- 2. Live: the installed release carries the list ---
# The agents read it when they start; step 3 shows that they did.
LIVE="$(kubectl -n "${ISTIO_NAMESPACE}" get configmap istio-cni-config -o jsonpath='{.data.EXCLUDE_NAMESPACES}')"
if [ "${LIVE}" != "kube-system,${ISTIO_NAMESPACE}" ]; then
  fail "the installed EXCLUDE_NAMESPACES is '${LIVE}', expected 'kube-system,${ISTIO_NAMESPACE}'"
fi
echo "OK: the installed release excludes ${ISTIO_NAMESPACE}"

# --- 3. A node with a stale plugin ---
# Narrowing the selector deletes the agent pods while the DaemonSet stays, so
# each agent leaves the plugin on its node, and no agent comes back.
park_agents
kubectl -n "${ISTIO_NAMESPACE}" wait --for=delete pod -l k8s-app=istio-cni-node --timeout=180s

# The API server caches a successful token review for a while, so a probe
# created right after the agents stop can still start. Such a probe is deleted
# and created again until the plugin rejects one, for up to three minutes.
kubectl create namespace "${OTHER_NS}"
POISONED=""
DEADLINE=$((SECONDS + 180))
while [ -z "${POISONED}" ] && [ "${SECONDS}" -lt "${DEADLINE}" ]; do
  run_probe "${OTHER_NS}"
  for _ in $(seq 1 12); do
    if kubectl -n "${OTHER_NS}" get events \
        --field-selector "involvedObject.name=${PROBE},reason=FailedCreatePodSandBox" \
        -o jsonpath='{.items[*].message}' | grep -q 'failed (add): Unauthorized'; then
      POISONED="yes"
      break
    fi
    if [ "$(kubectl -n "${OTHER_NS}" get pod "${PROBE}" -o jsonpath='{.status.phase}')" == "Running" ]; then
      break
    fi
    sleep 5
  done
  if [ -z "${POISONED}" ]; then
    kubectl -n "${OTHER_NS}" delete pod "${PROBE}" --wait=true --timeout=60s
  fi
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
