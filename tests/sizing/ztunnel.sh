#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Measurement 6: ztunnel memory against the size of the cluster and per
# connection. Sourced by measure.sh, which holds the helpers; uses the fortio
# setup of traffic.sh.
#
# ztunnel gets every workload and Service of the cluster from istiod, on every
# node, whether the node runs them or not. The fake pods of KWOK are such
# workloads; the ztunnel measured is the one on a real node.
# ---------------------------------------------------------------------------

# Fake Services the pods are spread over, and the pods: the replicas per
# Service are ZTUNNEL_PODS / ZTUNNEL_SERVICES.
ZTUNNEL_SERVICES="${ZTUNNEL_SERVICES:-100}"
ZTUNNEL_PODS="${ZTUNNEL_PODS:-1000 2000 4000}"
ZTUNNEL_BULK_SERVICES="${ZTUNNEL_BULK_SERVICES:-1000 2000}"
ZTUNNEL_CONNECTIONS="${ZTUNNEL_CONNECTIONS:-500 1000 2000}"

# ztunnel_pod <node>: the Ready ztunnel pod of a node.
ztunnel_pod() {
  local pods
  for _ in $(seq 1 60); do
    pods=$(kubectl get pod -n "${ISTIO_NAMESPACE}" -l app=ztunnel --field-selector "spec.nodeName=$1" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
    if [ "$(grep -c . <<<"${pods}")" -eq 1 ] &&
       kubectl wait -n "${ISTIO_NAMESPACE}" --for=condition=Ready "pod/${pods}" --timeout=5s >/dev/null 2>&1; then
      echo "${pods}"
      return 0
    fi
    sleep 5
  done
  fail "no single Ready ztunnel pod on $1"
}

restart_ztunnel() {
  local pod
  pod=$(ztunnel_pod "$1")
  log "restarting ${pod}"
  kubectl delete pod -n "${ISTIO_NAMESPACE}" "${pod}" --wait=true >/dev/null
  ztunnel_pod "$1" >/dev/null
}

# ztunnel_counts <pod>: "<workloads> <services>" ztunnel holds, from the
# config_dump of its admin port, which listens on localhost only.
ztunnel_counts() {
  local pod="$1" port pf out
  port=$((20000 + RANDOM % 20000))
  out=$(mktemp)
  kubectl port-forward -n "${ISTIO_NAMESPACE}" "pod/${pod}" "${port}:15000" >/dev/null 2>&1 &
  pf=$!
  for _ in $(seq 1 20); do
    curl -sf -o "${out}" "http://127.0.0.1:${port}/config_dump" && break
    sleep 0.5
  done
  kill "${pf}" 2>/dev/null || true
  wait "${pf}" 2>/dev/null || true
  python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    print("- -")
    sys.exit()
print(len(d.get("workloads", [])), len(d.get("services", [])))
' "${out}"
  rm -f "${out}"
}

# ztunnel_wait_settled <pod> <min workloads> <min services>: waits until the
# counts reach the minimums and hold over three reads, then prints them.
ztunnel_wait_settled() {
  local pod="$1" minw="$2" mins="$3" prev="" same=0 cur w s
  for _ in $(seq 1 120); do
    cur=$(ztunnel_counts "${pod}")
    read -r w s <<<"${cur}"
    if [ "${w}" != "-" ] && [ "${w}" -ge "${minw}" ] && [ "${s}" -ge "${mins}" ] && [ "${cur}" = "${prev}" ]; then
      same=$((same + 1))
      if [ "${same}" -ge 3 ]; then
        sleep 15
        echo "${cur}"
        return 0
      fi
    else
      same=0
    fi
    prev="${cur}"
    sleep 5
  done
  fail "ztunnel ${pod} did not settle at >= ${minw} workloads and ${mins} Services (last ${cur})"
}

# record_ztunnel <measurement> <proxy> <pod> <workloads> <services> [<column>=<value>...]
record_ztunnel() {
  local exp="$1" proxy="$2" pod="$3" w="$4" s="$5" ws peak mc
  shift 5
  read -r ws peak mc _ < <(container_stats "${ISTIO_NAMESPACE}" "${pod}")
  emit_row "measurement=${exp}" "proxy=${proxy}" \
    "cpu_limit=$(limit_of "${ISTIO_NAMESPACE}" "${pod}" cpu)" "memory_limit=$(limit_of "${ISTIO_NAMESPACE}" "${pod}" memory)" \
    "workloads=${w}" "working_set_mi=${ws}" "peak_mi=${peak}" "cpu_m=${mc}" "$@"
  log "${exp} ${proxy}: $* workloads=${w} services_seen=${s} ws=${ws}Mi peak=${peak}Mi cpu=${mc}m"
}

# ztunnel_pod_series <measurement> <namespace> <ambient>: fake pods in a
# namespace in the mesh or outside it, read on a fresh ztunnel each step.
ztunnel_pod_series() {
  local exp="$1" ns="$2" ambient="$3" node pod p r counts
  node=$(worker_nodes | head -1)
  if [ "${ambient}" = true ]; then
    ensure_namespace "${ns}" istio.io/dataplane-mode=ambient
  else
    ensure_namespace "${ns}"
  fi
  fake_apps_create "${ns}" app 1 "${ZTUNNEL_SERVICES}" 0 "${ambient}"
  for p in 0 ${ZTUNNEL_PODS}; do
    r=$((p / ZTUNNEL_SERVICES))
    fake_apps_scale "${ns}" app "${r}"
    fake_pods_wait "${ns}" app $((r * ZTUNNEL_SERVICES))
    restart_ztunnel "${node}"
    pod=$(ztunnel_pod "${node}")
    counts=$(ztunnel_wait_settled "${pod}" $((r * ZTUNNEL_SERVICES)) "${ZTUNNEL_SERVICES}")
    # shellcheck disable=SC2086 # two numbers
    record_ztunnel "${exp}" ztunnel "${pod}" ${counts} \
      pods=$((r * ZTUNNEL_SERVICES)) services="${ZTUNNEL_SERVICES}"
  done
  delete_namespace "${ns}"
}

measure_ztunnel() {
  local node pod n c counts zc zs
  log "6. ztunnel memory against the pods and Services of the cluster, then per connection"
  fake_require
  reset_bulk
  reset_wp_services
  fake_nodes_ensure "$(tr ' ' '\n' <<<"${ZTUNNEL_PODS}" | sort -n | tail -1)"

  ztunnel_pod_series ztunnel-mesh-pods sizing-zt-mesh true
  ztunnel_pod_series ztunnel-other-pods sizing-zt-other false

  # Services without endpoints.
  node=$(worker_nodes | head -1)
  for n in 0 ${ZTUNNEL_BULK_SERVICES}; do
    ensure_bulk "${n}" 1
    restart_ztunnel "${node}"
    pod=$(ztunnel_pod "${node}")
    counts=$(ztunnel_wait_settled "${pod}" 1 "${n}")
    # shellcheck disable=SC2086 # two numbers
    record_ztunnel ztunnel-services ztunnel "${pod}" ${counts} services="${n}" pods=0
  done
  reset_bulk

  # Connections from client-mesh to echo-direct: through the ztunnel of the
  # client node, then the ztunnel of the server node, no waypoint.
  setup_traffic
  for c in 0 ${ZTUNNEL_CONNECTIONS}; do
    restart_ztunnel "${CLIENT_NODE}"
    if [ "${SERVER_NODE}" != "${CLIENT_NODE}" ]; then
      restart_ztunnel "${SERVER_NODE}"
    fi
    zc=$(ztunnel_pod "${CLIENT_NODE}")
    zs=$(ztunnel_pod "${SERVER_NODE}")
    wait_path client-mesh "$(direct_url)"
    if [ "${c}" -gt 0 ]; then
      run_load client-mesh "$(direct_url)" "${c}" "${c}"
      sleep "${LOAD_READ_AFTER}"
    fi
    if [ "${zc}" = "${zs}" ]; then
      record_ztunnel ztunnel-connections ztunnel-both "${zc}" - - connections="${c}" rps="${c}"
    else
      record_ztunnel ztunnel-connections ztunnel-client "${zc}" - - connections="${c}" rps="${c}"
      record_ztunnel ztunnel-connections ztunnel-server "${zs}" - - connections="${c}" rps="${c}"
    fi
    wait_load
  done
  traffic_teardown
}
