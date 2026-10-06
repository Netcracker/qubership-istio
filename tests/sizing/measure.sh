#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# The measurements of docs/internal/hardware-sizing-calibration.md, which give
# the coefficients of docs/internal/hardware-sizing-model.md.
#
#   clusters   1. Envoy memory per cluster and base: a gateway against the
#              Services of the cluster (one and two ports, flag off and on), a
#              waypoint against its bound Service ports and against the cluster
#   workers    2. memory per cluster of a gateway at CPU limits 1, 2 and 4,
#              which give 1, 2 and 4 Envoy workers
#   startup    3. peak memory of a gateway pod while it loads its first config
#   endpoints  4. Envoy memory per endpoint, on the gateway and the waypoint
#   traffic    5. gateway and waypoint memory per open connection and per
#              request in flight, with their CPU per request rate
#   ztunnel    6. ztunnel memory against the pods and Services of the cluster,
#              and per connection
#   istiod     7. istiod memory against Services, pods, routes and connected
#              proxies, and its CPU against pod churn
#
# Usage: tests/sizing/measure.sh [measurement...]   (default: all, in that order)
#
# Each reading appends one row to ${OUT_DIR}/measurements.csv;
# tests/sizing/report.py turns the file into the report.
#
# Needs a cluster with the qubership-istio chart installed and the Gateway API
# CRDs. endpoints, ztunnel and istiod need KWOK (tests/lib/fake.sh); traffic
# and ztunnel pull the fortio image; the connected proxies of istiod need
# pilot-load, given as PILOT_LOAD=<path to the binary>, and are skipped
# without it. traffic and ztunnel put the fortio client and server on two
# different worker nodes when there are two.
#
# Creates the namespaces sizing-* and fake nodes and deletes them at the end
# (KEEP_RESOURCES=true keeps them). Part of "clusters" sets
# PILOT_FILTER_GATEWAY_CLUSTER_CONFIG=true on istiod through helm, which
# changes every gateway of that istiod, and "ztunnel" and "istiod" restart
# ztunnel and istiod: run it on a cluster of its own. On a shared one set
# SKIP_FLAG_TOGGLE=true and run neither ztunnel nor istiod.
# ---------------------------------------------------------------------------
set -euo pipefail

ISTIO_NAMESPACE="${ISTIO_NAMESPACE:-istio-system}"
HELM_RELEASE="${HELM_RELEASE:-qubership-istio}"
HELM_CHART_PATH="${HELM_CHART_PATH:-}"
SKIP_FLAG_TOGGLE="${SKIP_FLAG_TOGGLE:-false}"
KEEP_RESOURCES="${KEEP_RESOURCES:-false}"
PILOT_LOAD="${PILOT_LOAD:-}"
OUT_DIR="${OUT_DIR:-sizing-results}"
CSV="${OUT_DIR}/measurements.csv"
ALL_MEASUREMENTS=(clusters workers startup endpoints traffic ztunnel istiod)

# One row per reading. Every row has the first five columns; the others are
# empty where a measurement has nothing to say.
CSV_COLUMNS=(
  measurement proxy istio_version cpu_limit memory_limit workers
  services ports_per_service bound_ports referenced flag
  active_clusters heap_mi allocated_mi working_set_mi peak_mi cds_kb lds_kb rds_kb
  endpoints_per_service hosts pods
  connections inflight payload_kb rps cpu_m
  workloads config_objects fake_proxies xds_clients
  churn_per_min window_s cpu_s pushes convergence_ms
)

GW_NS=sizing-gw
GW_NAME=sizing-gw
WP_NS=sizing-wp
WP_NAME=sizing-waypoint
BULK_NS=sizing-bulk
FLAG=PILOT_FILTER_GATEWAY_CLUSTER_CONFIG
# Proxies get a memory limit far above what they use, so nothing is OOMKilled
# while it is measured.
PROXY_MEMORY_LIMIT=2Gi

SIZING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SIZING_DIR}/.." && pwd)/lib"
source "${LIB_DIR}/utils.sh"
source "${LIB_DIR}/proxy.sh"
source "${LIB_DIR}/fake.sh"

# What the cluster holds so far.
BULK_COUNT=0
BULK_PORTS=1
WP_COUNT=0
FLAG_STATE=false
ISTIO_VERSION=""

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

if [ "$#" -eq 0 ]; then
  set -- "${ALL_MEASUREMENTS[@]}"
fi
for e in "$@"; do
  case " ${ALL_MEASUREMENTS[*]} " in
    *" ${e} "*) ;;
    *) fail "unknown measurement '${e}', expected: ${ALL_MEASUREMENTS[*]}" ;;
  esac
done
if [ "${SKIP_FLAG_TOGGLE}" != "true" ] && [ -z "${HELM_CHART_PATH}" ]; then
  fail "HELM_CHART_PATH is needed to toggle ${FLAG}, or set SKIP_FLAG_TOGGLE=true"
fi

# ---------------------------------------------------------------------------
# Rows
# ---------------------------------------------------------------------------

# emit_row <column>=<value>...: appends one row. A later value of a column
# replaces an earlier one; "-" is written as empty.
emit_row() {
  local -A row=([istio_version]="${ISTIO_VERSION}")
  local kv line="" c v
  for kv in "$@"; do
    row["${kv%%=*}"]="${kv#*=}"
  done
  for c in "${CSV_COLUMNS[@]}"; do
    v="${row[${c}]:-}"
    [ "${v}" = "-" ] && v=""
    line+="${v},"
  done
  echo "${line%,}" >> "${CSV}"
}

# xds_size_kb <namespace> <pod> <CDS|LDS|RDS>: size in kB (1000 bytes, as
# istiod logs it) of the last push of that type to the proxy, from the istiod
# log, when that push was a full one. A proxy that grew into its config got
# incremental pushes ("PUSH INC"), which carry only the changes, so the value
# is empty for it, as it is when the log no longer has the push.
xds_size_kb() {
  { kubectl logs -n "${ISTIO_NAMESPACE}" deploy/istiod --since=30m 2>/dev/null || true; } |
    grep -F "$3: PUSH" | grep -F "node:$2.$1 " | tail -1 | grep -vF "$3: PUSH INC" |
    sed -n 's/.* size:\([0-9.]*\)\([kMG]\{0,1\}B\).*/\1 \2/p' |
    awk '{ m = ($2 == "MB") ? 1000 : ($2 == "GB") ? 1000000 : ($2 == "B") ? 0.001 : 1; printf "%.1f", $1 * m }' ||
    true
}

limit_of() {
  kubectl get pod -n "$1" "$2" -o jsonpath="{.spec.containers[?(@.name==\"${4:-istio-proxy}\")].resources.limits.$3}"
}

# record <measurement> <proxy> <namespace> <pod> <min clusters> [<column>=<value>...]
# Reads a gateway or waypoint and appends one row. With a number as <min
# clusters>, first waits for its config to settle at that many clusters or
# more; with "-", reads it as it is.
#
# heap_mi is server.memory_physical_size: what tcmalloc holds from the system.
# It does not shrink when the config does, so a proxy is measured on a fresh
# pod after anything that lowers its cluster count (restart_gateway).
# allocated_mi is server.memory_allocated, the part in use.
record() {
  local exp="$1" proxy="$2" ns="$3" pod="$4" min="$5"
  shift 5
  local clusters heap allocated workers ws peak mc
  if [ "${min}" = "-" ]; then
    clusters=$(proxy_stat "${ns}" "${pod}" cluster_manager.active_clusters)
  else
    clusters=$(proxy_wait_clusters_settled "${ns}" "${pod}" "${min}")
  fi
  heap=$(proxy_stat "${ns}" "${pod}" server.memory_physical_size | awk '{printf "%.1f", $1/1048576}')
  allocated=$(proxy_stat "${ns}" "${pod}" server.memory_allocated | awk '{printf "%.1f", $1/1048576}')
  workers=$(proxy_stat "${ns}" "${pod}" server.concurrency)
  read -r ws peak mc _ < <(container_stats "${ns}" "${pod}")
  emit_row "measurement=${exp}" "proxy=${proxy}" \
    "cpu_limit=$(limit_of "${ns}" "${pod}" cpu)" "memory_limit=$(limit_of "${ns}" "${pod}" memory)" \
    "workers=${workers}" "flag=${FLAG_STATE}" "active_clusters=${clusters}" \
    "heap_mi=${heap}" "allocated_mi=${allocated}" "working_set_mi=${ws}" "peak_mi=${peak}" "cpu_m=${mc}" \
    "cds_kb=$(xds_size_kb "${ns}" "${pod}" CDS)" "lds_kb=$(xds_size_kb "${ns}" "${pod}" LDS)" \
    "rds_kb=$(xds_size_kb "${ns}" "${pod}" RDS)" "$@"
  log "${exp} ${proxy}: $* workers=${workers} clusters=${clusters} heap=${heap}Mi allocated=${allocated}Mi ws=${ws}Mi peak=${peak}Mi cpu=${mc}m"
}

# ---------------------------------------------------------------------------
# Cluster state
# ---------------------------------------------------------------------------

gw_pod() { proxy_pod "${GW_NS}" "gateway.networking.k8s.io/gateway-name=${GW_NAME}"; }
wp_pod() { proxy_pod "${WP_NS}" "gateway.networking.k8s.io/gateway-name=${WP_NAME}"; }

# ensure_namespace <name> [<label>=<value>...]
ensure_namespace() {
  local ns="$1"
  shift
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  if [ "$#" -gt 0 ]; then
    kubectl label namespace "${ns}" --overwrite "$@" >/dev/null
  fi
}

# delete_namespace <name>: deletes it and waits until it is gone.
delete_namespace() {
  kubectl delete namespace "$1" --ignore-not-found --wait=true --timeout=10m >/dev/null
}

reset_bulk() {
  log "resetting ${BULK_NS}"
  delete_namespace "${BULK_NS}"
  ensure_namespace "${BULK_NS}"
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

# reset_wp_services: the waypoint namespace back to the waypoint alone.
reset_wp_services() {
  kubectl delete service -n "${WP_NS}" -l tests/services=svc --ignore-not-found --wait=true >/dev/null
  WP_COUNT=0
  traffic_teardown
}

# apply_gateway <cpu limit>: the gateway with its proxy resources.
apply_gateway() {
  fixtures_apply --set-string \
    "gateway.name=${GW_NAME},gateway.namespace=${GW_NS},gateway.cpuLimit=$1,gateway.memoryLimit=${PROXY_MEMORY_LIMIT}"
}

setup_gateway() {
  log "setting up gateway ${GW_NS}/${GW_NAME}"
  ensure_namespace "${GW_NS}"
  apply_gateway 1
  kubectl wait gateway/"${GW_NAME}" -n "${GW_NS}" --for=condition=Programmed --timeout=180s >/dev/null
}

setup_waypoint() {
  log "setting up waypoint ${WP_NS}/${WP_NAME}"
  ensure_namespace "${WP_NS}" istio.io/dataplane-mode=ambient "istio.io/use-waypoint=${WP_NAME}"
  fixtures_apply --set-string \
    "waypoint.name=${WP_NAME},waypoint.namespace=${WP_NS},waypoint.cpuLimit=2,waypoint.memoryLimit=${PROXY_MEMORY_LIMIT}"
  kubectl wait gateway/"${WP_NAME}" -n "${WP_NS}" --for=condition=Programmed --timeout=180s >/dev/null
}

# restart_gateway, restart_waypoint: replace the pod and wait for the new one.
restart_gateway() {
  local pod
  pod=$(gw_pod)
  log "restarting ${pod}"
  kubectl delete pod -n "${GW_NS}" "${pod}" --wait=true >/dev/null
  gw_pod >/dev/null
}

restart_waypoint() {
  local pod
  pod=$(wp_pod)
  log "restarting ${pod}"
  kubectl delete pod -n "${WP_NS}" "${pod}" --wait=true >/dev/null
  wp_pod >/dev/null
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
  FLAG_STATE="$1"
}

# worker_nodes: the real nodes that take ordinary pods, one per line; the
# control-plane node only when there is nothing else.
worker_nodes() {
  local nodes
  nodes=$(kubectl get nodes -l '!type,!pilot-load.istio.io/node,!node-role.kubernetes.io/control-plane' \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  if [ -z "${nodes}" ]; then
    nodes=$(kubectl get nodes -l '!type,!pilot-load.istio.io/node' \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  fi
  echo "${nodes}"
}

cleanup() {
  pilot_load_stop || true
  if [ "${FLAG_STATE}" = "true" ]; then
    set_flag false || true
  fi
  if [ "${KEEP_RESOURCES}" != "true" ]; then
    kubectl get namespace -o name | grep '^namespace/sizing-' |
      xargs -r kubectl delete --ignore-not-found --wait=false >/dev/null || true
    kubectl delete service istiod-sizing -n "${ISTIO_NAMESPACE}" --ignore-not-found >/dev/null || true
    fake_nodes_delete || true
  fi
}

# ---------------------------------------------------------------------------
# Measurements
# ---------------------------------------------------------------------------

source "${SIZING_DIR}/envoy.sh"
source "${SIZING_DIR}/traffic.sh"
source "${SIZING_DIR}/ztunnel.sh"
source "${SIZING_DIR}/istiod.sh"

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

mkdir -p "${OUT_DIR}"
if [ ! -s "${CSV}" ]; then
  (IFS=,; echo "${CSV_COLUMNS[*]}") > "${CSV}"
fi
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
