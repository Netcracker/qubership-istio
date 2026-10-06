#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Measurements 1 to 4: the idle memory of Envoy against its config. Sourced by
# measure.sh, which holds the helpers.
# ---------------------------------------------------------------------------

# Services with endpoints in measurement 4.
ENDPOINT_SERVICES="${ENDPOINT_SERVICES:-200}"

measure_clusters() {
  local gw wp gw_base wp_base on_base n k r
  log "1. Envoy memory per cluster: waypoint against its bound ports, gateway against the Services of the cluster"
  reset_bulk
  reset_wp_services
  set_gateway_cpu 1
  restart_waypoint
  gw=$(gw_pod)
  wp=$(wp_pod)

  # Waypoint against its bound Service ports, nothing in the bulk namespace.
  # The minimum is only the base: how many clusters a bound port adds is what
  # is measured.
  wp_base=$(proxy_wait_clusters_settled "${WP_NS}" "${wp}" 1)
  for k in 0 25 50 100 200; do
    ensure_wp_services "${k}"
    record waypoint-bound-ports waypoint "${WP_NS}" "${wp}" "${wp_base}" \
      services=0 ports_per_service=1 bound_ports="${k}" referenced=0
  done

  # Gateway against the Services of the cluster, and the waypoint with its 200
  # ports fixed, to see whether it follows the cluster too.
  gw_base=$(proxy_wait_clusters_settled "${GW_NS}" "${gw}" 1)
  for n in 0 250 500 1000 2000; do
    ensure_bulk "${n}" 1
    record gateway-services gateway "${GW_NS}" "${gw}" $((gw_base + n)) \
      services="${n}" ports_per_service=1 bound_ports=0 referenced=0
    record waypoint-cluster-services waypoint "${WP_NS}" "${wp}" "${wp_base}" \
      services="${n}" ports_per_service=1 bound_ports=200 referenced=0
  done

  # Flag on: the gateway keeps only the Services its routes reference.
  if [ "${SKIP_FLAG_TOGGLE}" != "true" ]; then
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
      record gateway-referenced-services gateway "${GW_NS}" "${gw}" $((on_base + r)) \
        services=2000 ports_per_service=1 bound_ports=0 referenced="${r}"
    done
    kubectl delete httproute -n "${BULK_NS}" -l tests/route=bulk --ignore-not-found >/dev/null
    set_flag false
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
    record gateway-services gateway "${GW_NS}" "${gw}" $((gw_base + 2 * n)) \
      services="${n}" ports_per_service=2 bound_ports=0 referenced=0
  done
}

measure_workers() {
  local gw cpu base
  log "2. Gateway memory per cluster against Envoy workers: CPU limits 1, 2 and 4"
  reset_bulk
  reset_wp_services
  for cpu in 1 2 4; do
    set_gateway_cpu "${cpu}"
    gw=$(gw_pod)
    record gateway-workers gateway "${GW_NS}" "${gw}" 1 services=0 ports_per_service=1
  done
  gw=$(gw_pod)
  base=$(proxy_wait_clusters_settled "${GW_NS}" "${gw}" 1)
  ensure_bulk 1000 1
  for cpu in 4 2 1; do
    set_gateway_cpu "${cpu}"
    gw=$(gw_pod)
    record gateway-workers gateway "${GW_NS}" "${gw}" $((base + 1000)) services=1000 ports_per_service=1
  done
}

measure_startup() {
  local gw base n
  log "3. Gateway memory peak while it loads its first config"
  reset_bulk
  reset_wp_services
  set_gateway_cpu 1
  gw=$(gw_pod)
  base=$(proxy_wait_clusters_settled "${GW_NS}" "${gw}" 1)
  for n in 1000 2000; do
    ensure_bulk "${n}" 1
    gw=$(gw_pod)
    proxy_wait_clusters_settled "${GW_NS}" "${gw}" $((base + n)) >/dev/null
    restart_gateway
    gw=$(gw_pod)
    record gateway-startup gateway "${GW_NS}" "${gw}" $((base + n)) services="${n}" ports_per_service=1
  done
}

# The Services of measurement 4 are in the waypoint namespace, so the waypoint
# serves them and the gateway sees them like every other Service. Their pods
# are fake and annotated as captured, as ambient pods are.
measure_endpoints() {
  local n="${ENDPOINT_SERVICES}" gw wp gw_base wp_base e hosts
  log "4. Envoy memory per endpoint: ${n} Services with 0, 1, 5 and 20 endpoints each, on the gateway and the waypoint"
  fake_require
  reset_bulk
  reset_wp_services
  fake_nodes_ensure $((n * 20))
  set_gateway_cpu 1
  restart_waypoint
  gw_base=$(proxy_wait_clusters_settled "${GW_NS}" "$(gw_pod)" 1)
  wp_base=$(proxy_wait_clusters_settled "${WP_NS}" "$(wp_pod)" 1)
  fake_apps_create "${WP_NS}" app 1 "${n}" 0 true
  for e in 0 1 5 20; do
    fake_apps_scale "${WP_NS}" app "${e}"
    fake_pods_wait "${WP_NS}" app $((n * e))
    restart_gateway
    restart_waypoint
    gw=$(gw_pod)
    wp=$(wp_pod)
    proxy_wait_clusters_settled "${GW_NS}" "${gw}" $((gw_base + n)) >/dev/null
    hosts=$(proxy_wait_endpoints "${GW_NS}" "${gw}" $((n * e)))
    record gateway-endpoints gateway "${GW_NS}" "${gw}" - \
      services="${n}" ports_per_service=1 endpoints_per_service="${e}" pods=$((n * e)) hosts="${hosts}"
    proxy_wait_clusters_settled "${WP_NS}" "${wp}" $((wp_base + 1)) >/dev/null
    hosts=$(proxy_wait_endpoints "${WP_NS}" "${wp}" $((n * e)))
    record waypoint-endpoints waypoint "${WP_NS}" "${wp}" - \
      bound_ports="${n}" ports_per_service=1 endpoints_per_service="${e}" pods=$((n * e)) hosts="${hosts}"
  done
  kubectl delete deployment,service -n "${WP_NS}" -l tests/apps=app --wait=true >/dev/null
  fake_pods_wait "${WP_NS}" app 0
}
