#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Pods that cost nothing to run: KWOK (sigs.k8s.io/kwok) keeps fake Nodes
# Ready and moves the pods scheduled to them to Running with a pod IP, without
# starting a container. istiod, ztunnel and the Envoy proxies see them as
# ordinary pods, endpoints and workloads. Sourced — not executed.
#
# Needs the KWOK controller and its fast stages in the cluster:
#   kubectl apply -f https://github.com/kubernetes-sigs/kwok/releases/download/<v>/kwok.yaml
#   kubectl apply -f https://github.com/kubernetes-sigs/kwok/releases/download/<v>/stage-fast.yaml
#
#   fake_require                       fail unless KWOK runs
#   fake_nodes_ensure <pods>           enough fake nodes for that many pods
#   fake_apps_create <ns> <prefix> <from> <to> <replicas> <ambient>
#   fake_apps_scale <ns> <prefix> <replicas>
#   fake_pods_wait <ns> <prefix> <count>
#   fake_nodes_delete
#
# Each fake node takes FAKE_PODS_PER_NODE pods, below the /24 pod CIDR the
# controller manager gives it, which KWOK takes the pod IPs from. Every
# DaemonSet that tolerates all taints (ztunnel, istio-cni, kindnet, kube-proxy)
# gets a fake pod on each fake node as well.
# ---------------------------------------------------------------------------

[ -n "${_TESTS_LIB_FAKE:-}" ] && return 0
_TESTS_LIB_FAKE=1

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/utils.sh"

FAKE_PODS_PER_NODE="${FAKE_PODS_PER_NODE:-200}"

fake_require() {
  kubectl get deployment kwok-controller -n kube-system >/dev/null 2>&1 ||
    fail "KWOK is not installed in kube-system, see tests/lib/fake.sh"
}

# fake_nodes_ensure <pods>
fake_nodes_ensure() {
  local need have
  need=$(( ($1 + FAKE_PODS_PER_NODE - 1) / FAKE_PODS_PER_NODE ))
  have=$(kubectl get nodes -l type=kwok -o name | grep -c . || true)
  if [ "${need}" -gt "${have}" ]; then
    log "creating fake nodes $((have + 1))..${need}"
    fixtures_create --set-string \
      "fakeNodes.from=$((have + 1)),fakeNodes.to=${need},fakeNodes.pods=$((FAKE_PODS_PER_NODE + 20))"
  fi
  kubectl wait node -l type=kwok --for=condition=Ready --timeout=120s >/dev/null
}

# fake_apps_create <namespace> <prefix> <from> <to> <replicas> <ambient: true|false>
fake_apps_create() {
  log "creating fake apps $2-$3..$2-$4 with $5 pod(s) each in $1"
  fixtures_create --set-string \
    "fakeApps.namespace=$1,fakeApps.prefix=$2,fakeApps.from=$3,fakeApps.to=$4,fakeApps.replicas=$5,fakeApps.ambient=$6"
}

# fake_apps_scale <namespace> <prefix> <replicas>
# kubectl scale sends one request per Deployment at the client-go default of 5
# per second, so the Deployments are split over parallel kubectl processes;
# nothing is sent when they all have that many replicas already.
fake_apps_scale() {
  local current
  current=$(kubectl get deployment -n "$1" -l "tests/apps=$2" \
    -o jsonpath='{range .items[*]}{.spec.replicas}{"\n"}{end}' | sort -u)
  if [ "${current}" = "$3" ]; then
    return 0
  fi
  log "scaling fake apps $2-* in $1 to $3 pod(s) each"
  kubectl get deployment -n "$1" -l "tests/apps=$2" -o name |
    xargs -r -P 8 -n 100 kubectl scale -n "$1" --replicas="$3" >/dev/null
}

# fake_pods_wait <namespace> <prefix> <count>
# Waits until exactly <count> pods of the apps run with a pod IP and no other
# pod of them is left, terminating ones included.
fake_pods_wait() {
  local ns="$1" prefix="$2" want="$3" all running
  for _ in $(seq 1 180); do
    all=$(kubectl get pods -n "${ns}" -l "tests/apps=${prefix}" --no-headers 2>/dev/null | grep -c . || true)
    running=$(kubectl get pods -n "${ns}" -l "tests/apps=${prefix}" --field-selector=status.phase=Running \
      -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}' 2>/dev/null | grep -c . || true)
    if [ "${all}" -eq "${want}" ] && [ "${running}" -eq "${want}" ]; then
      return 0
    fi
    sleep 5
  done
  fail "fake pods ${prefix}-* in ${ns}: ${running} running of ${all}, expected ${want}"
}

fake_nodes_delete() {
  kubectl delete node -l type=kwok --ignore-not-found --wait=false >/dev/null
}
