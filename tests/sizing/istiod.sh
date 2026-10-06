#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Measurement 7: istiod memory against the size of the cluster and the proxies
# connected to it, and its CPU against pod churn. Sourced by measure.sh, which
# holds the helpers.
#
# Pods are fake (KWOK). Connected proxies are simulated by pilot-load
# (github.com/howardjohn/pilot-load): each fake ztunnel or waypoint opens an
# xDS stream to istiod, authenticated by a service account token, and
# receives what a real one would; pilot-load registers the nodes and pods
# that go with them.
# ---------------------------------------------------------------------------

ISTIOD_NS=sizing-istiod
CHURN_NS=sizing-churn
ISTIOD_ROUTES="${ISTIOD_ROUTES:-250 500 1000}"
ISTIOD_ZTUNNELS="${ISTIOD_ZTUNNELS:-25 50 100}"
ISTIOD_WAYPOINTS="${ISTIOD_WAYPOINTS:-10 25 50}"
# Deployment restarts per minute, each replacing two pods; and how long each runs.
ISTIOD_CHURN="${ISTIOD_CHURN:-30 90}"
CHURN_DEPLOYMENTS=100
CHURN_SECONDS="${CHURN_SECONDS:-180}"
ISTIOD_NODE_PORT=31012

PILOT_LOAD_PID=""
PILOT_LOAD_LOG=""

istiod_pod() { proxy_pod "${ISTIO_NAMESPACE}" app=istiod; }

# istiod_metrics <pod>: "<Services> <connected proxies> <heap in use MiB>
# <heap allocated MiB> <CPU seconds> <pushes> <convergence sum s> <convergence count>"
# from its monitoring port, through the API server.
istiod_metrics() {
  { kubectl get --raw "/api/v1/namespaces/${ISTIO_NAMESPACE}/pods/$1:15014/proxy/metrics" 2>/dev/null || true; } |
    python3 -c '
import sys
want = ["pilot_services", "pilot_xds", "go_memstats_heap_inuse_bytes", "go_memstats_alloc_bytes",
        "process_cpu_seconds_total", "pilot_xds_pushes",
        "pilot_proxy_convergence_time_sum", "pilot_proxy_convergence_time_count"]
sums = {}
for line in sys.stdin:
    if line.startswith("#") or not line.strip():
        continue
    name, _, rest = line.partition(" ")
    if "{" in line:
        name = line.split("{", 1)[0]
        rest = line.rsplit("}", 1)[1]
    if name in want:
        try:
            sums[name] = sums.get(name, 0.0) + float(rest.split()[0])
        except (IndexError, ValueError):
            pass
out = []
for n in want:
    v = sums.get(n)
    if v is None:
        out.append("-")
    elif n.startswith("go_memstats"):
        out.append("%.1f" % (v / 1048576))
    elif n in ("process_cpu_seconds_total", "pilot_proxy_convergence_time_sum"):
        out.append("%.3f" % v)
    else:
        out.append("%d" % v)
print(" ".join(out))
'
}

# istiod_wait_settled <min Services> <min connected proxies>: waits until
# istiod has synced that many Services, that many proxies are connected, and
# the push counter holds over three reads; then lets the garbage collector run.
istiod_wait_settled() {
  local mins="$1" minx="$2" pod prev="" same=0 s x p
  pod=$(istiod_pod)
  for _ in $(seq 1 120); do
    read -r s x _ _ _ p _ _ < <(istiod_metrics "${pod}")
    if [[ "${s}" =~ ^[0-9]+$ && "${x}" =~ ^[0-9]+$ ]] &&
       [ "${s}" -ge "${mins}" ] && [ "${x}" -ge "${minx}" ] && [ "${p}" = "${prev}" ]; then
      same=$((same + 1))
      if [ "${same}" -ge 3 ]; then
        sleep 30
        return 0
      fi
    else
      same=0
    fi
    prev="${p}"
    sleep 10
  done
  fail "istiod did not settle at >= ${mins} Services and ${minx} proxies (last ${s} and ${x})"
}

# istiod_proxies: the number of proxies connected to istiod.
istiod_proxies() {
  local x
  for _ in $(seq 1 30); do
    read -r _ x _ < <(istiod_metrics "$(istiod_pod)")
    if [[ "${x}" =~ ^[0-9]+$ ]]; then
      echo "${x}"
      return 0
    fi
    sleep 5
  done
  fail "cannot read pilot_xds from istiod"
}

restart_istiod() {
  log "restarting istiod"
  kubectl rollout restart deployment/istiod -n "${ISTIO_NAMESPACE}" >/dev/null
  kubectl rollout status deployment/istiod -n "${ISTIO_NAMESPACE}" --timeout=300s >/dev/null
}

# record_istiod <measurement> [<column>=<value>...]
# heap_mi is the Go heap in use, allocated_mi the live objects in it.
record_istiod() {
  local exp="$1" pod s x heap alloc ws peak mc
  shift
  pod=$(istiod_pod)
  read -r s x heap alloc _ < <(istiod_metrics "${pod}")
  read -r ws peak mc _ < <(container_stats "${ISTIO_NAMESPACE}" "${pod}" discovery)
  emit_row "measurement=${exp}" proxy=istiod \
    "cpu_limit=$(limit_of "${ISTIO_NAMESPACE}" "${pod}" cpu discovery)" \
    "memory_limit=$(limit_of "${ISTIO_NAMESPACE}" "${pod}" memory discovery)" \
    "xds_clients=${x}" "heap_mi=${heap}" "allocated_mi=${alloc}" \
    "working_set_mi=${ws}" "peak_mi=${peak}" "cpu_m=${mc}" "$@"
  log "${exp}: $* services_seen=${s} proxies=${x} heap=${heap}Mi alloc=${alloc}Mi ws=${ws}Mi cpu=${mc}m"
}

# istiod_size_step <Services> <pods per Service>: fake apps app-1..app-<Services>
# with that many pods each, then a fresh istiod, then one row.
ISTIOD_APPS=0
istiod_size_step() {
  local s="$1" r="$2" proxies
  if [ "${s}" -gt "${ISTIOD_APPS}" ]; then
    fake_apps_create "${ISTIOD_NS}" app $((ISTIOD_APPS + 1)) "${s}" "${r}" true
    ISTIOD_APPS="${s}"
  fi
  fake_apps_scale "${ISTIOD_NS}" app "${r}"
  fake_pods_wait "${ISTIOD_NS}" app $((s * r))
  proxies=$(istiod_proxies)
  restart_istiod
  istiod_wait_settled "${s}" "${proxies}"
  record_istiod istiod-cluster-size services="${s}" pods=$((s * r))
}

# pilot_load_start <config file>: runs pilot-load in the background against
# istiod's port 15012, through a NodePort Service.
pilot_load_start() {
  local addr
  addr=$(kubectl get nodes -l '!type,!pilot-load.istio.io/node' \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
  PILOT_LOAD_LOG="${OUT_DIR}/pilot-load.log"
  echo "--- $(date +%H:%M:%S) $(tr '\n' ' ' <"$1")" >>"${PILOT_LOAD_LOG}"
  "${PILOT_LOAD}" cluster --config "$1" --pilot-address "${addr}:${ISTIOD_NODE_PORT}" --auth jwt \
    >>"${PILOT_LOAD_LOG}" 2>&1 &
  PILOT_LOAD_PID=$!
}

# pilot_load_stop: stops pilot-load, which deletes what it created; removes
# what is left if it does not stop in time.
pilot_load_stop() {
  [ -n "${PILOT_LOAD_PID}" ] || return 0
  kill -INT "${PILOT_LOAD_PID}" 2>/dev/null || true
  for _ in $(seq 1 60); do
    kill -0 "${PILOT_LOAD_PID}" 2>/dev/null || break
    sleep 2
  done
  kill -KILL "${PILOT_LOAD_PID}" 2>/dev/null || true
  wait "${PILOT_LOAD_PID}" 2>/dev/null || true
  PILOT_LOAD_PID=""
  kubectl delete node -l pilot-load.istio.io/node=fake --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl get namespace -o name | grep '^namespace/sizing-pl' |
    xargs -r kubectl delete --ignore-not-found --wait=true --timeout=5m >/dev/null 2>&1 || true
}

# pilot_load_ztunnels <count> <file>: a pilot-load config with that many fake
# nodes, each with a ztunnel.
pilot_load_ztunnels() {
  cat >"$2" <<YAML
stableNames: true
nodes:
- name: sizing-pl-zt
  count: $1
  ztunnel: {}
YAML
}

# pilot_load_waypoints <count> <file>: that many namespaces, each with a
# waypoint and a Service of two ambient pods bound to it.
pilot_load_waypoints() {
  cat >"$2" <<YAML
stableNames: true
namespaces:
- name: sizing-pl
  replicas: $1
  waypoint: waypoint
  applications:
  - name: waypoint
    pods: 1
    type: waypoint
  - name: app
    pods: 2
    type: ambient
nodes:
- name: sizing-pl-node
  count: 1
YAML
}

# connected_step <measurement> <count> <config writer>
connected_step() {
  local exp="$1" n="$2" writer="$3" base cfg
  base=$(istiod_proxies)
  cfg="${OUT_DIR}/pilot-load-${exp}-${n}.yaml"
  "${writer}" "${n}" "${cfg}"
  pilot_load_start "${cfg}"
  istiod_wait_settled 1 $((base + n))
  record_istiod "${exp}" fake_proxies="${n}" services="${ISTIOD_APPS}" pods="${ISTIOD_APPS}"
  pilot_load_stop
}

# churn_step <restarts per minute> <fake ztunnels>
churn_step() {
  local k="$1" z="$2" pod m0 m1 c0 c1 p0 p1 s0 s1 n0 n1 t0 t1 i=0 interval cfg conv base
  if [ "${z}" -gt 0 ]; then
    base=$(istiod_proxies)
    cfg="${OUT_DIR}/pilot-load-churn-${z}.yaml"
    pilot_load_ztunnels "${z}" "${cfg}"
    pilot_load_start "${cfg}"
    istiod_wait_settled 1 $((base + z))
  else
    sleep 30
  fi
  pod=$(istiod_pod)
  m0=$(istiod_metrics "${pod}")
  t0=$(date +%s)
  if [ "${k}" -gt 0 ]; then
    interval=$(awk -v k="${k}" 'BEGIN { printf "%.3f", 60 / k }')
    while [ $(( $(date +%s) - t0 )) -lt "${CHURN_SECONDS}" ]; do
      kubectl rollout restart deployment "churn-$((i % CHURN_DEPLOYMENTS + 1))" -n "${CHURN_NS}" >/dev/null
      i=$((i + 1))
      sleep "${interval}"
    done
  else
    sleep "${CHURN_SECONDS}"
  fi
  t1=$(date +%s)
  m1=$(istiod_metrics "${pod}")
  read -r _ _ _ _ c0 p0 s0 n0 <<<"${m0}"
  read -r _ _ _ _ c1 p1 s1 n1 <<<"${m1}"
  conv=$(awk -v a="${s0}" -v b="${s1}" -v c="${n0}" -v d="${n1}" \
    'BEGIN { if (d > c) printf "%.1f", (b - a) / (d - c) * 1000; else print "-" }')
  record_istiod istiod-churn churn_per_min=$(( i * 60 / (t1 - t0) )) fake_proxies="${z}" \
    window_s=$((t1 - t0)) cpu_s="$(awk -v a="${c0}" -v b="${c1}" 'BEGIN { printf "%.2f", b - a }')" \
    pushes=$((p1 - p0)) convergence_ms="${conv}" \
    services=$((ISTIOD_APPS + CHURN_DEPLOYMENTS)) pods=$((ISTIOD_APPS + 2 * CHURN_DEPLOYMENTS))
  if [ "${z}" -gt 0 ]; then
    pilot_load_stop
  fi
  fake_pods_wait "${CHURN_NS}" churn $((2 * CHURN_DEPLOYMENTS))
}

measure_istiod() {
  local n k
  log "7. istiod memory against Services, pods, routes and connected proxies; CPU against pod churn"
  fake_require
  reset_bulk
  reset_wp_services
  delete_namespace "${ISTIOD_NS}"
  ensure_namespace "${ISTIOD_NS}" istio.io/dataplane-mode=ambient
  ISTIOD_APPS=0
  fake_nodes_ensure 4200

  # Services and pods: 1, 2 and 4 pods per Service at 1000 Services, then
  # 2000 and 4000 Services with one pod each.
  istiod_size_step 500 1
  istiod_size_step 1000 1
  istiod_size_step 1000 2
  istiod_size_step 1000 4
  istiod_size_step 2000 1
  istiod_size_step 4000 1

  # HTTPRoutes of one rule each, attached to the gateway, at 4000 Services.
  record_istiod istiod-routes config_objects=0 services=4000 pods=4000
  for n in ${ISTIOD_ROUTES}; do
    fixtures_apply --set-string \
      "routes.namespace=${ISTIOD_NS},routes.gateway=${GW_NAME},routes.gatewayNamespace=${GW_NS},routes.servicePrefix=app,routes.count=${n},routes.rulesPerRoute=1"
    restart_istiod
    istiod_wait_settled 4000 1
    record_istiod istiod-routes config_objects="${n}" services=4000 pods=4000
  done
  kubectl delete httproute -n "${ISTIOD_NS}" -l tests/route=bulk --ignore-not-found >/dev/null

  # Connected proxies, simulated.
  if [ -n "${PILOT_LOAD}" ] && [ -x "${PILOT_LOAD}" ]; then
    fixtures_apply --set-string \
      "istiodNodePort.namespace=${ISTIO_NAMESPACE},istiodNodePort.nodePort=${ISTIOD_NODE_PORT}"
    restart_istiod
    istiod_wait_settled 4000 1
    record_istiod istiod-ztunnels fake_proxies=0 services=4000 pods=4000
    for n in ${ISTIOD_ZTUNNELS}; do
      connected_step istiod-ztunnels "${n}" pilot_load_ztunnels
    done
    record_istiod istiod-waypoints fake_proxies=0 services=4000 pods=4000
    for n in ${ISTIOD_WAYPOINTS}; do
      connected_step istiod-waypoints "${n}" pilot_load_waypoints
    done
  else
    log "PILOT_LOAD not set: connected proxies not measured"
  fi

  # Churn: Deployments restarted at a steady rate, with only the real proxies
  # connected, then with 50 fake ztunnels as well.
  ensure_namespace "${CHURN_NS}" istio.io/dataplane-mode=ambient
  fake_apps_create "${CHURN_NS}" churn 1 "${CHURN_DEPLOYMENTS}" 2 true
  fake_pods_wait "${CHURN_NS}" churn $((2 * CHURN_DEPLOYMENTS))
  restart_istiod
  istiod_wait_settled 4000 1
  for k in 0 ${ISTIOD_CHURN}; do
    churn_step "${k}" 0
  done
  if [ -n "${PILOT_LOAD}" ] && [ -x "${PILOT_LOAD}" ]; then
    k=$(awk '{print $NF}' <<<"${ISTIOD_CHURN}")
    churn_step "${k}" 50
  fi
  delete_namespace "${CHURN_NS}"
  delete_namespace "${ISTIOD_NS}"
}
