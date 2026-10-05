#!/usr/bin/env bash
set -eux

# ---------------------------------------------------------------------------
# istiod.env.PILOT_FILTER_GATEWAY_CLUSTER_CONFIG and the
# envoyfilter.istio.io/referenced-services annotation.
#
# A gateway gets one Envoy cluster per Service port. Without the flag it gets
# the clusters of every Service in the cluster; with the flag only those of the
# Services it references. The test reads the clusters of the gateway pod:
#
#   routed      backend of an HTTPRoute of the gateway   kept with the flag
#   unrouted    no route                                 dropped with the flag
#   referenced  named only by an EnvoyFilter cluster_name dropped with the flag,
#                                                         back once the EnvoyFilter
#                                                         carries the annotation,
#                                                         lost again on a route
#                                                         change (istio/istio#TBD)
#   late        Service and HTTPRoute created after the flag is on, then the
#               route deleted: cluster added, then removed
#   bulk-*      20 Services without routes: active_clusters drops by at least 20
#
# The flag restarts istiod, and the test leaves it as the chart default.
# ---------------------------------------------------------------------------

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TEST_DIR}/../lib/utils.sh"
source "${TEST_DIR}/../lib/proxy.sh"

GW_NAME=cluster-filter-gw
GW_SELECTOR="gateway.networking.k8s.io/gateway-name=${GW_NAME}"
NS=cluster-filter-test
BULK_NS=cluster-filter-bulk
BULK_COUNT=20
EF_NAME=cluster-filter-ext-proc
FLAG=PILOT_FILTER_GATEWAY_CLUSTER_CONFIG
DOMAIN=svc.cluster.local

cluster_of() {
  echo "outbound|80||$1.${2:-${NS}}.${DOMAIN}"
}

set_flag() {
  istiod_set_env "${FLAG}" "$1"
}

cleanup() {
  set_flag false || true
  kubectl delete envoyfilter "${EF_NAME}" -n "${ISTIO_NAMESPACE}" --ignore-not-found
  kubectl delete gateway "${GW_NAME}" -n "${ISTIO_NAMESPACE}" --ignore-not-found
  kubectl delete configmap "${GW_NAME}-options" -n "${ISTIO_NAMESPACE}" --ignore-not-found
  kubectl delete namespace "${NS}" "${BULK_NS}" --ignore-not-found
}
trap cleanup EXIT

gw_pod() {
  proxy_pod "${ISTIO_NAMESPACE}" "${GW_SELECTOR}"
}

# The pod is looked up before use, so a missing pod fails here rather than as
# an empty pod name further down.
gw_admin() {
  local pod
  pod=$(gw_pod) || return 1
  proxy_admin "${ISTIO_NAMESPACE}" "${pod}" "$1"
}

# wait_cluster present|absent <cluster>
wait_cluster() {
  local pod
  pod=$(gw_pod)
  proxy_wait_cluster "${ISTIO_NAMESPACE}" "${pod}" "$1" "$2"
}

expect_cluster() {
  local want="$1" cluster="$2" pod
  pod=$(gw_pod)
  if proxy_has_cluster "${ISTIO_NAMESPACE}" "${pod}" "${cluster}"; then
    [ "${want}" = present ] || fail "cluster ${cluster}: expected absent, found present"
  else
    [ "${want}" = absent ] || fail "cluster ${cluster}: expected present, found absent"
  fi
  ok "${cluster} ${want}"
}

active_clusters() {
  local pod
  pod=$(gw_pod) || return 1
  proxy_stat "${ISTIO_NAMESPACE}" "${pod}" cluster_manager.active_clusters
}

# The listener still carries the ext_proc filter, so Envoy accepted the
# EnvoyFilter patch whether or not its cluster exists.
expect_ext_proc_in_listener() {
  for _ in $(seq 1 12); do
    if gw_admin 'config_dump?resource=dynamic_listeners' | grep -q 'envoy.filters.http.ext_proc'; then
      ok "ext_proc filter is in the gateway listener"
      return 0
    fi
    sleep 5
  done
  fail "ext_proc filter missing from the gateway listener"
}

curl_gw() {
  local path="${1:-/get}"
  local port=18083
  kubectl port-forward -n "${ISTIO_NAMESPACE}" "svc/${GW_NAME}-istio" "${port}:80" >/dev/null 2>&1 &
  local pf_pid=$!
  sleep 2
  curl -sf -o /dev/null "http://127.0.0.1:${port}${path}"
  local exit_code=$?
  kill "${pf_pid}" 2>/dev/null || true
  wait "${pf_pid}" 2>/dev/null || true
  return ${exit_code}
}

expect_traffic() {
  for i in $(seq 1 12); do
    curl_gw /get && { ok "traffic flows through the gateway"; return 0; }
    log "waiting for traffic through the gateway (${i}/12)"
    sleep 5
  done
  fail "HTTP traffic through the gateway failed"
}

# apply_route <name> <backend> <path prefix>
apply_route() {
  fixtures_apply \
    --set-string "httpRoute.name=$1,httpRoute.namespace=${NS}" \
    --set-string "httpRoute.gateway=${GW_NAME},httpRoute.gatewayNamespace=${ISTIO_NAMESPACE}" \
    --set-string "httpRoute.backend=$2,httpRoute.pathPrefix=$3"
}

# ---------------------------------------------------------------------------
# 0. The chart default is off
# ---------------------------------------------------------------------------
DEFAULT=$(kubectl get deployment istiod -n "${ISTIO_NAMESPACE}" \
  -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name==\"${FLAG}\")].value}")
if [ "${DEFAULT}" != "false" ]; then
  fail "${FLAG} on istiod: expected 'false', got '${DEFAULT}'"
fi
ok "${FLAG}=false by default"

# ---------------------------------------------------------------------------
# 1. Services, Gateway, route
# ---------------------------------------------------------------------------
kubectl create namespace "${NS}"
kubectl create deployment routed --image=mccutchen/go-httpbin:v2.15.0 --port=8080 -n "${NS}"
kubectl expose deployment routed --port=80 --target-port=8080 -n "${NS}"
# Services without endpoints still get clusters.
kubectl create service clusterip unrouted --tcp=80:8080 -n "${NS}"
kubectl create service clusterip referenced --tcp=80:8080 -n "${NS}"

kubectl create namespace "${BULK_NS}"
fixtures_create --set-string "services.namespace=${BULK_NS},services.prefix=bulk,services.from=1,services.to=${BULK_COUNT}"

kubectl rollout status deployment/routed -n "${NS}" --timeout=120s

fixtures_apply --set-string "gateway.name=${GW_NAME},gateway.namespace=${ISTIO_NAMESPACE}"
kubectl wait gateway/"${GW_NAME}" -n "${ISTIO_NAMESPACE}" --for=condition=Programmed --timeout=120s
kubectl rollout status "deployment/${GW_NAME}-istio" -n "${ISTIO_NAMESPACE}" --timeout=120s

apply_route routed routed /
expect_traffic

# ---------------------------------------------------------------------------
# 2. An EnvoyFilter that names the cluster of "referenced" and nothing else
#    does: no route of the gateway points at that Service
# ---------------------------------------------------------------------------
fixtures_apply \
  --set-string "clusterRefFilter.name=${EF_NAME},clusterRefFilter.namespace=${ISTIO_NAMESPACE}" \
  --set-string "clusterRefFilter.gateway=${GW_NAME}" \
  --set-string "clusterRefFilter.cluster=$(cluster_of referenced)"

# ---------------------------------------------------------------------------
# 3. Flag off: the gateway gets every Service
# ---------------------------------------------------------------------------
wait_cluster present "$(cluster_of "bulk-${BULK_COUNT}" "${BULK_NS}")"
expect_cluster present "$(cluster_of routed)"
expect_cluster present "$(cluster_of unrouted)"
expect_cluster present "$(cluster_of referenced)"
expect_ext_proc_in_listener
ACTIVE_OFF=$(active_clusters)
log "active_clusters with the flag off: ${ACTIVE_OFF}"

# ---------------------------------------------------------------------------
# 4. Flag on: only referenced Services; the EnvoyFilter loses its cluster
#    without the annotation, and Envoy still accepts the listener
# ---------------------------------------------------------------------------
set_flag true

wait_cluster absent "$(cluster_of unrouted)"
expect_cluster present "$(cluster_of routed)"
expect_cluster absent "$(cluster_of referenced)"
expect_cluster absent "$(cluster_of bulk-1 "${BULK_NS}")"
expect_ext_proc_in_listener
expect_traffic

ACTIVE_ON=$(active_clusters)
if [ $((ACTIVE_OFF - ACTIVE_ON)) -lt "${BULK_COUNT}" ]; then
  fail "active_clusters: expected a drop of at least ${BULK_COUNT}, got ${ACTIVE_OFF} -> ${ACTIVE_ON}"
fi
ok "active_clusters dropped from ${ACTIVE_OFF} to ${ACTIVE_ON}"

# ---------------------------------------------------------------------------
# 5. The annotation brings the cluster back
# ---------------------------------------------------------------------------
kubectl annotate envoyfilter "${EF_NAME}" -n "${ISTIO_NAMESPACE}" \
  "envoyfilter.istio.io/referenced-services=${NS}/referenced.${NS}.${DOMAIN}"

wait_cluster present "$(cluster_of referenced)"
expect_cluster absent "$(cluster_of unrouted)"
expect_traffic

# ---------------------------------------------------------------------------
# 6. Changes while the flag is on: a new Service and its route add a cluster,
#    deleting the route removes it.
#    Known issue istio/istio#TBD: a route change is an incremental push, which
#    leaves out the Services of the annotation, so "referenced" is lost. When
#    this step fails on "referenced", the fix has arrived: expect it present
#    here, drop step 7, and update "Gateway cluster filtering" in
#    docs/public/installation.md and the comment of the flag in values.yaml.
# ---------------------------------------------------------------------------
kubectl create service clusterip late --tcp=80:8080 -n "${NS}"
apply_route late late /late

wait_cluster present "$(cluster_of late)"
wait_cluster absent "$(cluster_of referenced)"

kubectl delete httproute late -n "${NS}"
wait_cluster absent "$(cluster_of late)"
expect_cluster present "$(cluster_of routed)"
expect_cluster absent "$(cluster_of referenced)"
expect_traffic

# ---------------------------------------------------------------------------
# 7. A full push brings the annotated cluster back: any change to the
#    EnvoyFilter. Only annotations with istio.io in the name trigger a push.
# ---------------------------------------------------------------------------
kubectl annotate envoyfilter "${EF_NAME}" -n "${ISTIO_NAMESPACE}" --overwrite \
  "test.istio.io/touch=$(date +%s)"

wait_cluster present "$(cluster_of referenced)"
expect_cluster present "$(cluster_of routed)"
expect_traffic
