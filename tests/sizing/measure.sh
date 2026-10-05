#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Calibration runs for docs/internal/hardware-sizing-model.md, section 12.
#
#   clusters  Envoy memory per cluster and base: a gateway against the number
#             of Services in the cluster (one and two ports, flag off and on),
#             a waypoint against its bound Service ports and against the cluster
#   workers   memory per cluster of a gateway at CPU limits 1, 2 and 4, which
#             give 1, 2 and 4 Envoy workers
#   startup   peak memory of a gateway pod while it loads its first config
#
# Usage: tests/sizing/measure.sh [clusters] [workers] [startup]   (default: all)
#
# Each measurement appends one row to ${OUT_DIR}/measurements.csv;
# tests/sizing/report.py turns the file into the report.
#
# Needs a cluster with the qubership-istio chart installed and the Gateway API
# CRDs. Creates the namespaces sizing-gw, sizing-wp and sizing-bulk and deletes
# them at the end (KEEP_RESOURCES=true keeps them). Part of "clusters" sets
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
CSV_HEADER="measurement,proxy,istio_version,cpu_limit,memory_limit,workers,services,ports_per_service,bound_ports,referenced,flag,active_clusters,heap_mi,allocated_mi,working_set_mi,peak_mi,cds_kb,lds_kb,rds_kb"

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
  set -- clusters workers startup
fi
for e in "$@"; do
  case "${e}" in
    clusters|workers|startup) ;;
    *) fail "unknown measurement '${e}', expected clusters, workers or startup" ;;
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

# xds_size_kb <namespace> <pod> <CDS|LDS|RDS>: size in kB of the last full push
# of that type to the proxy, from the istiod log; empty when the log no longer
# has it. "PUSH INC" lines are incremental pushes that carry only the changed
# resources, so they are skipped.
xds_size_kb() {
  { kubectl logs -n "${ISTIO_NAMESPACE}" deploy/istiod --since=30m 2>/dev/null || true; } |
    grep -F "$3: PUSH" | grep -vF "$3: PUSH INC" | grep -F "node:$2.$1 " | tail -1 |
    sed -n 's/.* size:\([0-9.]*\)\([kMG]\{0,1\}B\).*/\1 \2/p' |
    awk '{ m = ($2 == "MB") ? 1024 : ($2 == "GB") ? 1048576 : ($2 == "B") ? 1/1024 : 1; printf "%.1f", $1 * m }' ||
    true
}

limit_of() {
  kubectl get pod -n "$1" "$2" -o jsonpath="{.spec.containers[?(@.name==\"istio-proxy\")].resources.limits.$3}"
}

# record <measurement> <proxy> <namespace> <pod> <services> <ports> <bound> <referenced> <flag> <min clusters>
# Waits for the proxy config to settle, then appends one CSV row.
#
# heap_mi is server.memory_physical_size: what tcmalloc holds from the system.
# It does not shrink when the config does, so a proxy is measured on a fresh
# pod after anything that lowers its cluster count (restart_gateway).
# allocated_mi is server.memory_allocated, the part in use.
record() {
  local exp="$1" proxy="$2" ns="$3" pod="$4" services="$5" ports="$6" bound="$7" referenced="$8" flag="$9" min="${10}"
  local clusters heap allocated workers ws peak cds lds rds
  clusters=$(proxy_wait_clusters_settled "${ns}" "${pod}" "${min}")
  heap=$(proxy_stat "${ns}" "${pod}" server.memory_physical_size | awk '{printf "%.1f", $1/1048576}')
  allocated=$(proxy_stat "${ns}" "${pod}" server.memory_allocated | awk '{printf "%.1f", $1/1048576}')
  workers=$(proxy_stat "${ns}" "${pod}" server.concurrency)
  read -r ws peak < <(proxy_memory "${ns}" "${pod}")
  [ "${ws}" = "-" ] && ws=""
  [ "${peak}" = "-" ] && peak=""
  cds=$(xds_size_kb "${ns}" "${pod}" CDS)
  lds=$(xds_size_kb "${ns}" "${pod}" LDS)
  rds=$(xds_size_kb "${ns}" "${pod}" RDS)
  echo "${exp},${proxy},${ISTIO_VERSION},$(limit_of "${ns}" "${pod}" cpu),$(limit_of "${ns}" "${pod}" memory),${workers},${services},${ports},${bound},${referenced},${flag},${clusters},${heap},${allocated},${ws},${peak},${cds},${lds},${rds}" >> "${CSV}"
  log "${exp} ${proxy}: services=${services} ports=${ports} bound=${bound} referenced=${referenced} flag=${flag} workers=${workers} clusters=${clusters} heap=${heap}Mi allocated=${allocated}Mi ws=${ws:-?}Mi peak=${peak:-?}Mi"
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

# restart_gateway: replaces the gateway pod and waits for the new one.
restart_gateway() {
  local pod
  pod=$(gw_pod)
  log "restarting ${pod}"
  kubectl delete pod -n "${GW_NS}" "${pod}" --wait=true >/dev/null
  gw_pod >/dev/null
}

# set_gateway_cpu <limit>: a fresh gateway pod with that CPU limit, also when
# the limit does not change.
set_gateway_cpu() {
  local cpu="$1" old pod
  old=$(gw_pod)
  if [ "$(limit_of "${GW_NS}" "${old}" cpu)" = "${cpu}" ]; then
    restart_gateway
    return 0
  fi
  apply_gateway "${cpu}"
  for _ in $(seq 1 60); do
    pod=$(gw_pod)
    [ "${pod}" != "${old}" ] && [ "$(limit_of "${GW_NS}" "${pod}" cpu)" = "${cpu}" ] && return 0
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
# Measurements. Each CSV row names what it measures: proxy, then the variable.
# ---------------------------------------------------------------------------

measure_clusters() {
  local gw wp gw_base wp_base on_base n k r
  log "1. Envoy memory per cluster: waypoint against its bound ports, gateway against the Services of the cluster"
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
    record waypoint-bound-ports waypoint "${WP_NS}" "${wp}" 0 1 "${k}" 0 false "${wp_base}"
  done

  # Gateway against the Services of the cluster, and the waypoint with its 200
  # ports fixed, to see whether it follows the cluster too.
  gw_base=$(proxy_wait_clusters_settled "${GW_NS}" "${gw}" 1)
  for n in 0 250 500 1000 2000; do
    ensure_bulk "${n}" 1
    record gateway-services gateway "${GW_NS}" "${gw}" "${n}" 1 0 0 false $((gw_base + n))
    record waypoint-cluster-services waypoint "${WP_NS}" "${wp}" "${n}" 1 200 0 false "${wp_base}"
  done

  # Flag on: the gateway keeps only the Services its routes reference.
  if [ "${SKIP_FLAG_TOGGLE}" != "true" ]; then
    FLAG_TOGGLED=true
    set_flag true
    proxy_wait_clusters_below "${GW_NS}" "${gw}" $((gw_base + 1000))
    restart_gateway
    gw=$(gw_pod)
    on_base=$(proxy_wait_clusters_settled "${GW_NS}" "${gw}" 1)
    for r in 0 250 1000; do
      if [ "${r}" -gt 0 ]; then
        fixtures_apply --set-string \
          "routes.namespace=${BULK_NS},routes.gateway=${GW_NAME},routes.gatewayNamespace=${GW_NS},routes.servicePrefix=svc,routes.count=${r}"
      fi
      record gateway-referenced-services gateway "${GW_NS}" "${gw}" 2000 1 0 "${r}" true $((on_base + r))
    done
    kubectl delete httproute -n "${BULK_NS}" -l tests/route=bulk --ignore-not-found >/dev/null
    set_flag false
    FLAG_TOGGLED=false
  else
    log "SKIP_FLAG_TOGGLE=true: gateway with ${FLAG} not measured"
  fi

  # Two ports per Service, on a fresh pod: the bulk namespace starts empty.
  reset_bulk
  BULK_PORTS=2
  restart_gateway
  gw=$(gw_pod)
  for n in 250 1000; do
    ensure_bulk "${n}" 2
    record gateway-services gateway "${GW_NS}" "${gw}" "${n}" 2 0 0 false $((gw_base + 2 * n))
  done
}

measure_workers() {
  local gw cpu base
  log "2. Gateway memory per cluster against Envoy workers: CPU limits 1, 2 and 4"
  reset_bulk
  for cpu in 1 2 4; do
    set_gateway_cpu "${cpu}"
    gw=$(gw_pod)
    record gateway-workers gateway "${GW_NS}" "${gw}" 0 1 0 0 false 1
  done
  gw=$(gw_pod)
  base=$(proxy_wait_clusters_settled "${GW_NS}" "${gw}" 1)
  ensure_bulk 1000 1
  for cpu in 4 2 1; do
    set_gateway_cpu "${cpu}"
    gw=$(gw_pod)
    record gateway-workers gateway "${GW_NS}" "${gw}" 1000 1 0 0 false $((base + 1000))
  done
}

measure_startup() {
  local gw base n
  log "3. Gateway memory peak while it loads its first config"
  reset_bulk
  set_gateway_cpu 1
  gw=$(gw_pod)
  base=$(proxy_wait_clusters_settled "${GW_NS}" "${gw}" 1)
  for n in 1000 2000; do
    ensure_bulk "${n}" 1
    gw=$(gw_pod)
    proxy_wait_clusters_settled "${GW_NS}" "${gw}" $((base + n)) >/dev/null
    restart_gateway
    gw=$(gw_pod)
    record gateway-startup gateway "${GW_NS}" "${gw}" "${n}" 1 0 0 false $((base + n))
  done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

mkdir -p "${OUT_DIR}"
[ -s "${CSV}" ] || echo "${CSV_HEADER}" > "${CSV}"
ISTIO_VERSION=$(kubectl get deployment istiod -n "${ISTIO_NAMESPACE}" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*://')
log "Istio ${ISTIO_VERSION}, measurements: $*"

trap cleanup EXIT
setup_gateway
setup_waypoint
for e in "$@"; do
  "measure_${e}"
done
log "done: ${CSV}"
