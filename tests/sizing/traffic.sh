#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Measurement 5: gateway and waypoint memory under load, and the fortio setup
# measurement 6 reuses. Sourced by measure.sh, which holds the helpers.
#
# fortio runs in the waypoint namespace: the server behind the Service echo,
# which the namespace binds to the waypoint, and behind echo-direct, which is
# not bound; the client outside the mesh, for the gateway; the client-mesh in
# the mesh, for the waypoint and ztunnel. The clients go on one worker node,
# the server on another when there is one, so ztunnel carries the traffic
# between two nodes as it does in a real cluster.
# ---------------------------------------------------------------------------

# Open connections at about one request per second each: what a connection costs.
TRAFFIC_CONNECTIONS="${TRAFFIC_CONNECTIONS:-500 1000 2000}"
# Connections that each keep one request in flight: what a request costs.
TRAFFIC_INFLIGHT="${TRAFFIC_INFLIGHT:-500 1000}"
# How long the server holds a request in flight.
TRAFFIC_DELAY_S=2
# Each load runs LOAD_SECONDS; the proxy is read LOAD_READ_AFTER seconds in.
LOAD_SECONDS="${LOAD_SECONDS:-75}"
LOAD_READ_AFTER="${LOAD_READ_AFTER:-50}"

CLIENT_NODE=""
SERVER_NODE=""
LOAD_PID=""
LOAD_LOG=""
LOAD_FIELDS=()
# A load whose errors exceed this share of requests, or that opened more than
# 10% more sockets than connections (keep-alive failing), is marked load_ok=false.
LOAD_MAX_ERRORS_PCT=1

client_pod() { proxy_pod "${WP_NS}" "app=$1"; }

# fortio_ok <client> <url>: one request answered with 200. The output is read
# whole first: grep -q on a pipe would end kubectl with SIGPIPE, which
# pipefail turns into a failure.
fortio_ok() {
  local out
  out=$(kubectl exec -n "${WP_NS}" "$(client_pod "$1")" -c fortio -- /usr/bin/fortio curl -quiet "$2" 2>&1) || true
  grep -q ' 200 ' <<<"${out}"
}

# wait_path <client> <url>
wait_path() {
  for _ in $(seq 1 36); do
    fortio_ok "$1" "$2" && return 0
    sleep 5
  done
  fail "${1} gets no 200 from ${2}"
}

gateway_url() { echo "http://${GW_NAME}-istio.${GW_NS}.svc.cluster.local/echo"; }
waypoint_url() { echo "http://echo.${WP_NS}.svc.cluster.local/echo"; }
direct_url() { echo "http://echo-direct.${WP_NS}.svc.cluster.local/echo"; }

setup_traffic() {
  local nodes
  nodes=$(worker_nodes)
  CLIENT_NODE=$(sed -n 1p <<<"${nodes}")
  SERVER_NODE=$(sed -n 2p <<<"${nodes}")
  SERVER_NODE="${SERVER_NODE:-${CLIENT_NODE}}"
  log "fortio: clients on ${CLIENT_NODE}, server on ${SERVER_NODE}"
  fixtures_apply --set-string \
    "fortio.namespace=${WP_NS},fortio.clientNode=${CLIENT_NODE},fortio.serverNode=${SERVER_NODE}"
  fixtures_apply --set-string \
    "httpRoute.name=echo,httpRoute.namespace=${WP_NS},httpRoute.gateway=${GW_NAME},httpRoute.gatewayNamespace=${GW_NS},httpRoute.backend=echo"
  kubectl rollout status deployment/echo deployment/client deployment/client-mesh -n "${WP_NS}" --timeout=300s >/dev/null
  wait_path client "$(gateway_url)"
  wait_path client-mesh "$(waypoint_url)"
  wait_path client-mesh "$(direct_url)"
}

traffic_teardown() {
  kubectl delete deployment echo client client-mesh -n "${WP_NS}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kubectl delete service echo echo-direct -n "${WP_NS}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete httproute echo -n "${WP_NS}" --ignore-not-found >/dev/null 2>&1 || true
}

# run_load <client> <url> <connections> <requests per second> [<body bytes>]
# Starts fortio in the background for LOAD_SECONDS, requests spread evenly
# over the connections, a body of that size in both directions. Without
# -allow-initial-errors fortio gives up when one warmup request of a
# connection fails, and the proxy is then read with no load on it.
run_load() {
  local client="$1" url="$2" c="$3" qps="$4" body="${5:-0}" args=()
  if [ "${body}" -gt 0 ]; then
    args=(-payload-size "${body}")
    url="${url}$( [[ "${url}" == *\?* ]] && echo '&' || echo '?')size=${body}"
  fi
  LOAD_LOG=$(mktemp)
  log "load: ${c} connections, ${qps} requests/s, ${body} B bodies, ${url}"
  kubectl exec -n "${WP_NS}" "$(client_pod "${client}")" -c fortio -- \
    /usr/bin/fortio load -quiet -uniform -nocatchup -allow-initial-errors \
    -c "${c}" -qps "${qps}" -t "${LOAD_SECONDS}s" -timeout 30s \
    "${args[@]}" "${url}" >"${LOAD_LOG}" 2>&1 &
  LOAD_PID=$!
  LOAD_CONNECTIONS="${c}"
}

# wait_load: waits for the load to end, logs what fortio achieved and sets
# LOAD_FIELDS to the columns that say it: the rate it reached, the mean
# latency, the requests in flight these give (rate times latency), the
# sockets it opened, the share of failed requests, and load_ok.
wait_load() {
  local rc=0 summary
  LOAD_FIELDS=()
  [ -n "${LOAD_PID}" ] || return 0
  wait "${LOAD_PID}" || rc=$?
  LOAD_PID=""
  [ "${rc}" -eq 0 ] || log "fortio exited with ${rc}"
  grep -E 'Aborting|Sockets used|All done|^Code ' "${LOAD_LOG}" | sed 's/^/  fortio: /' >&2 || true
  summary=$(awk -v c="${LOAD_CONNECTIONS}" -v maxerr="${LOAD_MAX_ERRORS_PCT}" '
    /^Aborting/ { aborted = 1 }
    /^Sockets used:/ { sockets = $3 }
    /^All done/ { for (i = 1; i <= NF; i++) { if ($i == "ms") ms = $(i - 1); if ($i == "qps") qps = $(i - 1) } }
    /^Code 200 :/ { ok = $4 }
    /^Code / { total += $4 }
    END {
      err = total > 0 ? 100 * (total - ok) / total : 100
      good = (!aborted && qps != "" && err <= maxerr && sockets <= 1.1 * c) ? "true" : "false"
      printf "rps=%.0f latency_ms=%.1f inflight=%.0f sockets=%d load_errors_pct=%.2f load_ok=%s\n",
        qps, ms, qps * ms / 1000, sockets, err, good
    }' "${LOAD_LOG}")
  rm -f "${LOAD_LOG}"
  read -r -a LOAD_FIELDS <<<"${summary}"
  log "load: ${summary}"
}

# traffic_step <gateway|waypoint> <connections> <in flight: 0 or the connections> <body KiB>
# A fresh proxy pod, then the load, then one row.
traffic_step() {
  local proxy="$1" c="$2" inflight="$3" kib="$4" pod ns client url qps
  if [ "${proxy}" = gateway ]; then
    restart_gateway
    pod=$(gw_pod)
    ns="${GW_NS}" client=client url=$(gateway_url)
  else
    restart_waypoint
    pod=$(wp_pod)
    ns="${WP_NS}" client=client-mesh url=$(waypoint_url)
  fi
  proxy_wait_clusters_settled "${ns}" "${pod}" 1 >/dev/null
  wait_path "${client}" "${url}"
  qps="${c}"
  if [ "${inflight}" -gt 0 ]; then
    qps=$((c / TRAFFIC_DELAY_S))
    url="${url}?delay=${TRAFFIC_DELAY_S}s"
  fi
  if [ "${c}" -eq 0 ]; then
    record "${proxy}-traffic" "${proxy}" "${ns}" "${pod}" - \
      connections=0 inflight=0 payload_kb=0 rps=0
    return 0
  fi
  # The proxy is read under load; the row is written once fortio has said
  # what the load was.
  run_load "${client}" "${url}" "${c}" "${qps}" $((kib * 1024))
  sleep "${LOAD_READ_AFTER}"
  DEFER_ROWS=true
  record "${proxy}-traffic" "${proxy}" "${ns}" "${pod}" - \
    connections="${c}" payload_kb="${kib}" \
    open_connections="$(proxy_stat "${ns}" "${pod}" server.total_connections || echo -)"
  wait_load
  flush_rows "${LOAD_FIELDS[@]}"
}

measure_traffic() {
  local proxy c
  log "5. Gateway and waypoint memory per connection and per request in flight"
  reset_bulk
  reset_wp_services
  set_gateway_cpu 2
  setup_traffic
  for proxy in gateway waypoint; do
    traffic_step "${proxy}" 0 0 0
    for c in ${TRAFFIC_CONNECTIONS}; do
      traffic_step "${proxy}" "${c}" 0 0
    done
    for c in ${TRAFFIC_INFLIGHT}; do
      traffic_step "${proxy}" "${c}" "${c}" 1
    done
    c=$(awk '{print $1}' <<<"${TRAFFIC_INFLIGHT}")
    traffic_step "${proxy}" "${c}" "${c}" 100
  done
  set_gateway_cpu 1
}
