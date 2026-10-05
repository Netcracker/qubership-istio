#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Calibration runs for docs/internal/hardware-sizing-model.md, section 12.
#
#   m1  Envoy per-cluster cost and base: a gateway against the number of
#       Services in the cluster (one and two ports, flag off and on), a
#       waypoint against its bound Service ports and against the cluster
#   m3  per-cluster cost of a gateway at CPU limits 1, 2 and 4 (Envoy workers)
#   m4  peak memory of a gateway pod while it loads its first config
#
# Usage: tests/sizing/measure.sh [m1] [m3] [m4]     (default: all three)
#
# Each measurement appends one row to ${OUT_DIR}/measurements.csv;
# tests/sizing/report.py turns the file into the report.
#
# Needs a cluster with the qubership-istio chart installed and the Gateway API
# CRDs. Creates the namespaces sizing-gw, sizing-wp and sizing-bulk and deletes
# them at the end (KEEP_RESOURCES=true keeps them). Part of m1 sets
# PILOT_FILTER_GATEWAY_CLUSTER_CONFIG=true on istiod through helm, which
# changes every gateway of that istiod: on a shared cluster set
# SKIP_FLAG_TOGGLE=true.
# ---------------------------------------------------------------------------
set -euo pipefail

ISTIO_NAMESPACE="${ISTIO_NAMESPACE:-istio-system}"
HELM_RELEASE="${HELM_RELEASE:-qubership-istio}"
HELM_CHART_PATH="${HELM_CHART_PATH:-}"
SKIP_FLAG_TOGGLE="${SKIP_FLAG_TOGGLE:-false}"
KEEP_RESOURCES="${KEEP_RESOURCES:-false}"
OUT_DIR="${OUT_DIR:-sizing-results}"
CSV="${OUT_DIR}/measurements.csv"
CSV_HEADER="experiment,proxy,istio_version,cpu_limit,memory_limit,workers,services,ports_per_service,bound_ports,referenced,flag,active_clusters,heap_mi,working_set_mi,peak_mi,cds_kb,lds_kb,rds_kb"

GW_NS=sizing-gw
GW_NAME=sizing-gw
WP_NS=sizing-wp
WP_NAME=sizing-waypoint
BULK_NS=sizing-bulk
FLAG=PILOT_FILTER_GATEWAY_CLUSTER_CONFIG
# Proxies get a memory limit far above what they use, so nothing is OOMKilled
# while it is measured.
PROXY_MEMORY_LIMIT=2Gi

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib"
source "${LIB_DIR}/utils.sh"
source "${LIB_DIR}/proxy.sh"

# What the cluster holds so far.
BULK_COUNT=0
BULK_PORTS=1
WP_COUNT=0
FLAG_TOGGLED=false
ISTIO_VERSION=""

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

if [ "$#" -eq 0 ]; then
  set -- m1 m3 m4
fi
for e in "$@"; do
  case "${e}" in
    m1|m3|m4) ;;
    *) fail "unknown experiment '${e}', expected m1, m3 or m4" ;;
  esac
done
if [ "${SKIP_FLAG_TOGGLE}" != "true" ] && [ -z "${HELM_CHART_PATH}" ]; then
  fail "HELM_CHART_PATH is needed to toggle ${FLAG}, or set SKIP_FLAG_TOGGLE=true"
fi

# ---------------------------------------------------------------------------
# Reading a proxy
# ---------------------------------------------------------------------------

gw_pod() { proxy_pod "${GW_NS}" "gateway.networking.k8s.io/gateway-name=${GW_NAME}"; }
wp_pod() { proxy_pod "${WP_NS}" "gateway.networking.k8s.io/gateway-name=${WP_NAME}"; }

# cgroup_mem <namespace> <pod>: "<working set> <peak>" in MiB, from the cgroup
# of the istio-proxy container. The working set is what the kubelet reports:
# usage minus inactive file pages. memory.peak needs cgroup v2 on kernel 5.19
# or later; without it the peak reads 0.
cgroup_mem() {
  { kubectl exec -n "$1" "$2" -c istio-proxy -- \
      cat /sys/fs/cgroup/memory.current /sys/fs/cgroup/memory.stat /sys/fs/cgroup/memory.peak 2>/dev/null || true; } |
    awk 'NF==1 { if (!seen) { cur=$1; seen=1 } else { peak=$1 } }
         $1=="inactive_file" { inact=$2 }
         END { printf "%.1f %.1f\n", (cur-inact)/1048576, peak/1048576 }'
}

# xds_size_kb <namespace> <pod> <CDS|LDS|RDS>: size in kB of the last full push
# of that type to the proxy, from the istiod log; empty when the log no longer
# has it.
xds_size_kb() {
  { kubectl logs -n "${ISTIO_NAMESPACE}" deploy/istiod --since=30m 2>/dev/null || true; } |
    grep -F "$3: PUSH" | grep -F "node:$2.$1 " | tail -1 |
    sed -n 's/.* size:\([0-9.]*\)\([kMG]\{0,1\}B\).*/\1 \2/p' |
    awk '{ m = ($2 == "MB") ? 1024 : ($2 == "GB") ? 1048576 : ($2 == "B") ? 1/1024 : 1; printf "%.1f", $1 * m }' ||
    true
}

limit_of() {
  kubectl get pod -n "$1" "$2" -o jsonpath="{.spec.containers[?(@.name==\"istio-proxy\")].resources.limits.$3}"
}

# record <experiment> <proxy> <namespace> <pod> <services> <ports> <bound> <referenced> <flag> <min clusters>
# Waits for the proxy config to settle, then appends one CSV row.
record() {
  local exp="$1" proxy="$2" ns="$3" pod="$4" services="$5" ports="$6" bound="$7" referenced="$8" flag="$9" min="${10}"
  local clusters heap workers ws peak cds lds rds
  clusters=$(proxy_wait_clusters_settled "${ns}" "${pod}" "${min}")
  heap=$(proxy_stat "${ns}" "${pod}" server.memory_physical_size | awk '{printf "%.1f", $1/1048576}')
  workers=$(proxy_stat "${ns}" "${pod}" server.concurrency)
  read -r ws peak < <(cgroup_mem "${ns}" "${pod}")
  cds=$(xds_size_kb "${ns}" "${pod}" CDS)
  lds=$(xds_size_kb "${ns}" "${pod}" LDS)
  rds=$(xds_size_kb "${ns}" "${pod}" RDS)
  echo "${exp},${proxy},${ISTIO_VERSION},$(limit_of "${ns}" "${pod}" cpu),$(limit_of "${ns}" "${pod}" memory),${workers},${services},${ports},${bound},${referenced},${flag},${clusters},${heap},${ws},${peak},${cds},${lds},${rds}" >> "${CSV}"
  log "${exp} ${proxy}: services=${services} ports=${ports} bound=${bound} referenced=${referenced} flag=${flag} workers=${workers} clusters=${clusters} heap=${heap}Mi ws=${ws}Mi peak=${peak}Mi"
}

# ---------------------------------------------------------------------------
# Cluster state
# ---------------------------------------------------------------------------

reset_bulk() {
  log "resetting ${BULK_NS}"
  kubectl delete namespace "${BULK_NS}" --ignore-not-found --wait=true >/dev/null
  kubectl create namespace "${BULK_NS}" >/dev/null
  BULK_COUNT=0
}

# ensure_bulk <count> <ports>: Services svc-1..svc-<count> in the bulk namespace.
ensure_bulk() {
  local n="$1" ports="$2"
  if [ "${ports}" != "${BULK_PORTS}" ] || [ "${n}" -lt "${BULK_COUNT}" ]; then
    reset_bulk
    BULK_PORTS="${ports}"
  fi
  if [ "${n}" -gt "${BULK_COUNT}" ]; then
    log "creating Services $((BULK_COUNT + 1))..${n} with ${ports} port(s) in ${BULK_NS}"
    fixtures_create --set-string \
      "services.namespace=${BULK_NS},services.prefix=svc,services.from=$((BULK_COUNT + 1)),services.to=${n},services.ports=${ports}"
    BULK_COUNT="${n}"
  fi
}

# ensure_wp_services <count>: Services svc-1..svc-<count> bound to the waypoint.
ensure_wp_services() {
  local n="$1"
  if [ "${n}" -gt "${WP_COUNT}" ]; then
    fixtures_create --set-string \
      "services.namespace=${WP_NS},services.prefix=svc,services.from=$((WP_COUNT + 1)),services.to=${n}"
    WP_COUNT="${n}"
  fi
}

# apply_gateway <cpu limit>: the gateway with its proxy resources.
apply_gateway() {
  fixtures_apply --set-string \
    "gateway.name=${GW_NAME},gateway.namespace=${GW_NS},gateway.cpuLimit=$1,gateway.memoryLimit=${PROXY_MEMORY_LIMIT}"
}

setup_gateway() {
  log "setting up gateway ${GW_NS}/${GW_NAME}"
  kubectl create namespace "${GW_NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  apply_gateway 1
  kubectl wait gateway/"${GW_NAME}" -n "${GW_NS}" --for=condition=Programmed --timeout=180s >/dev/null
}

setup_waypoint() {
  log "setting up waypoint ${WP_NS}/${WP_NAME}"
  kubectl create namespace "${WP_NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label namespace "${WP_NS}" --overwrite \
    istio.io/dataplane-mode=ambient "istio.io/use-waypoint=${WP_NAME}" >/dev/null
  fixtures_apply --set-string \
    "waypoint.name=${WP_NAME},waypoint.namespace=${WP_NS},waypoint.cpuLimit=2,waypoint.memoryLimit=${PROXY_MEMORY_LIMIT}"
  kubectl wait gateway/"${WP_NAME}" -n "${WP_NS}" --for=condition=Programmed --timeout=180s >/dev/null
}

# set_gateway_cpu <limit>: waits for the gateway pod with that CPU limit.
set_gateway_cpu() {
  local cpu="$1" pod
  apply_gateway "${cpu}"
  for _ in $(seq 1 60); do
    pod=$(gw_pod)
    [ "$(limit_of "${GW_NS}" "${pod}" cpu)" = "${cpu}" ] && return 0
    sleep 5
  done
  fail "gateway did not roll to CPU limit ${cpu}"
}

set_flag() {
  istiod_set_env "${FLAG}" "$1"
}

cleanup() {
  if [ "${FLAG_TOGGLED}" = "true" ]; then
    set_flag false || true
  fi
  if [ "${KEEP_RESOURCES}" != "true" ]; then
    kubectl delete namespace "${GW_NS}" "${WP_NS}" "${BULK_NS}" --ignore-not-found --wait=false >/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Experiments
# ---------------------------------------------------------------------------

m1() {
  local gw wp gw_base wp_base on_base n k r
  log "m1: per-cluster cost and base"
  reset_bulk
  set_gateway_cpu 1
  gw=$(gw_pod)
  wp=$(wp_pod)

  # Waypoint against its bound Service ports, nothing in the bulk namespace.
  # The minimum is only the base: how many clusters a bound port adds is what
  # is measured.
  wp_base=$(proxy_wait_clusters_settled "${WP_NS}" "${wp}" 1)
  for k in 0 25 50 100 200; do
    ensure_wp_services "${k}"
    record m1-waypoint-ports waypoint "${WP_NS}" "${wp}" 0 1 "${k}" 0 false "${wp_base}"
  done

  # Gateway against the Services of the cluster, and the waypoint with its 200
  # ports fixed, to see whether it follows the cluster too.
  gw_base=$(proxy_wait_clusters_settled "${GW_NS}" "${gw}" 1)
  for n in 0 250 500 1000 2000; do
    ensure_bulk "${n}" 1
    record m1-gateway gateway "${GW_NS}" "${gw}" "${n}" 1 0 0 false $((gw_base + n))
    record m1-waypoint-cluster waypoint "${WP_NS}" "${wp}" "${n}" 1 200 0 false "${wp_base}"
  done

  # Flag on: the gateway keeps only the Services its routes reference.
  if [ "${SKIP_FLAG_TOGGLE}" != "true" ]; then
    FLAG_TOGGLED=true
    set_flag true
    proxy_wait_clusters_below "${GW_NS}" "${gw}" $((gw_base + 1000))
    on_base=$(proxy_wait_clusters_settled "${GW_NS}" "${gw}" 1)
    for r in 0 250 1000; do
      if [ "${r}" -gt 0 ]; then
        fixtures_apply --set-string \
          "routes.namespace=${BULK_NS},routes.gateway=${GW_NAME},routes.gatewayNamespace=${GW_NS},routes.servicePrefix=svc,routes.count=${r}"
      fi
      record m1-gateway-flag gateway "${GW_NS}" "${gw}" 2000 1 0 "${r}" true $((on_base + r))
    done
    kubectl delete httproute -n "${BULK_NS}" -l tests/route=bulk --ignore-not-found >/dev/null
    set_flag false
    FLAG_TOGGLED=false
  else
    log "m1: SKIP_FLAG_TOGGLE=true, no measurement with the flag on"
  fi

  # Two ports per Service.
  for n in 250 1000; do
    ensure_bulk "${n}" 2
    record m1-gateway gateway "${GW_NS}" "${gw}" "${n}" 2 0 0 false $((gw_base + 2 * n))
  done
}

m3() {
  local gw cpu base
  log "m3: per-cluster cost against Envoy workers"
  reset_bulk
  for cpu in 1 2 4; do
    set_gateway_cpu "${cpu}"
    gw=$(gw_pod)
    record m3-workers gateway "${GW_NS}" "${gw}" 0 1 0 0 false 1
  done
  gw=$(gw_pod)
  base=$(proxy_wait_clusters_settled "${GW_NS}" "${gw}" 1)
  ensure_bulk 1000 1
  for cpu in 4 2 1; do
    set_gateway_cpu "${cpu}"
    gw=$(gw_pod)
    record m3-workers gateway "${GW_NS}" "${gw}" 1000 1 0 0 false $((base + 1000))
  done
}

m4() {
  local gw base n
  log "m4: startup peak"
  reset_bulk
  set_gateway_cpu 1
  gw=$(gw_pod)
  base=$(proxy_wait_clusters_settled "${GW_NS}" "${gw}" 1)
  for n in 1000 2000; do
    ensure_bulk "${n}" 1
    gw=$(gw_pod)
    proxy_wait_clusters_settled "${GW_NS}" "${gw}" $((base + n)) >/dev/null
    log "m4: restarting ${gw}"
    kubectl delete pod -n "${GW_NS}" "${gw}" --wait=false >/dev/null
    sleep 5
    gw=$(gw_pod)
    record m4-startup gateway "${GW_NS}" "${gw}" "${n}" 1 0 0 false $((base + n))
  done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

mkdir -p "${OUT_DIR}"
[ -s "${CSV}" ] || echo "${CSV_HEADER}" > "${CSV}"
ISTIO_VERSION=$(kubectl get deployment istiod -n "${ISTIO_NAMESPACE}" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*://')
log "Istio ${ISTIO_VERSION}, experiments: $*"

trap cleanup EXIT
setup_gateway
setup_waypoint
for e in "$@"; do
  "${e}"
done
log "done: ${CSV}"
