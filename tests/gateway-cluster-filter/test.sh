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
#                                                         kept once the EnvoyFilter
#                                                         carries the annotation
#   late        Service and HTTPRoute created after the flag is on, then the
#               route deleted: cluster added, then removed
#   bulk-*      20 Services without routes: active_clusters drops by at least 20
#
# The flag restarts istiod, and the test leaves it as the chart default.
# ---------------------------------------------------------------------------

GW_NAME=cluster-filter-gw
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
  helm upgrade "${HELM_RELEASE}" "${HELM_CHART_PATH}" \
    --namespace "${ISTIO_NAMESPACE}" \
    --timeout 3m \
    --wait \
    --reuse-values \
    --set-string "istiod.env.${FLAG}=$1"
  kubectl rollout status deployment/istiod -n "${ISTIO_NAMESPACE}" --timeout=120s
}

cleanup() {
  set_flag false || true
  kubectl delete envoyfilter "${EF_NAME}" -n "${ISTIO_NAMESPACE}" --ignore-not-found
  kubectl delete gateway "${GW_NAME}" -n "${ISTIO_NAMESPACE}" --ignore-not-found
  kubectl delete namespace "${NS}" "${BULK_NS}" --ignore-not-found
}
trap cleanup EXIT

gw_pod() {
  kubectl get pod -n "${ISTIO_NAMESPACE}" -l "gateway.networking.k8s.io/gateway-name=${GW_NAME}" \
    --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}'
}

gw_admin() {
  kubectl exec -n "${ISTIO_NAMESPACE}" "$(gw_pod)" -c istio-proxy -- pilot-agent request GET "$1"
}

# Lines of GET clusters start with "<cluster name>::".
has_cluster() {
  gw_admin clusters 2>/dev/null | grep -qF "$1::"
}

# wait_cluster present|absent <cluster>: istiod pushes asynchronously.
wait_cluster() {
  local want="$1" cluster="$2"
  for i in $(seq 1 24); do
    if has_cluster "${cluster}"; then
      [ "${want}" = present ] && return 0
    else
      [ "${want}" = absent ] && return 0
    fi
    echo "Waiting for ${cluster} to be ${want} (attempt ${i}/24)..."
    sleep 5
  done
  gw_admin clusters | grep -F 'outbound|' | cut -d: -f1 | sort -u || true
  fail "cluster ${cluster}: expected ${want}"
}

expect_cluster() {
  local want="$1" cluster="$2"
  if has_cluster "${cluster}"; then
    [ "${want}" = present ] || fail "cluster ${cluster}: expected absent, found present"
  else
    [ "${want}" = absent ] || fail "cluster ${cluster}: expected present, found absent"
  fi
  echo "OK: ${cluster} ${want}"
}

active_clusters() {
  gw_admin 'stats?filter=^cluster_manager.active_clusters$' | awk '{print $2}'
}

# The listener still carries the ext_proc filter, so Envoy accepted the
# EnvoyFilter patch whether or not its cluster exists.
expect_ext_proc_in_listener() {
  gw_admin 'config_dump?resource=dynamic_listeners' | grep -q 'envoy.filters.http.ext_proc' \
    || fail "ext_proc filter missing from the gateway listener"
  echo "OK: ext_proc filter is in the gateway listener"
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
    curl_gw /get && { echo "OK: traffic flows through the gateway"; return 0; }
    echo "Attempt ${i}: waiting for traffic through the gateway..."
    sleep 5
  done
  fail "HTTP traffic through the gateway failed"
}

apply_route() {
  local name="$1" backend="$2" path="$3"
  kubectl apply -f - <<YAML
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ${name}
  namespace: ${NS}
spec:
  parentRefs:
  - name: ${GW_NAME}
    namespace: ${ISTIO_NAMESPACE}
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: ${path}
    backendRefs:
    - name: ${backend}
      port: 80
YAML
}

# ---------------------------------------------------------------------------
# 0. The chart default is off
# ---------------------------------------------------------------------------
DEFAULT=$(kubectl get deployment istiod -n "${ISTIO_NAMESPACE}" \
  -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name==\"${FLAG}\")].value}")
if [ "${DEFAULT}" != "false" ]; then
  fail "${FLAG} on istiod: expected 'false', got '${DEFAULT}'"
fi
echo "OK: ${FLAG}=false by default"

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
for i in $(seq 1 "${BULK_COUNT}"); do
  kubectl create service clusterip "bulk-${i}" --tcp=80:8080 -n "${BULK_NS}"
done

kubectl rollout status deployment/routed -n "${NS}" --timeout=120s

kubectl apply -f - <<YAML
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${GW_NAME}
  namespace: ${ISTIO_NAMESPACE}
spec:
  gatewayClassName: istio
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: All
YAML
kubectl wait gateway/"${GW_NAME}" -n "${ISTIO_NAMESPACE}" --for=condition=Programmed --timeout=120s
kubectl rollout status "deployment/${GW_NAME}-istio" -n "${ISTIO_NAMESPACE}" --timeout=120s

apply_route routed routed /
expect_traffic

# ---------------------------------------------------------------------------
# 2. An EnvoyFilter that names the cluster of "referenced" and nothing else
#    does: no route of the gateway points at that Service. All processing
#    modes are SKIP and failures are allowed, so the filter never touches
#    traffic.
# ---------------------------------------------------------------------------
kubectl apply -f - <<YAML
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: ${EF_NAME}
  namespace: ${ISTIO_NAMESPACE}
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: ${GW_NAME}
  configPatches:
  - applyTo: HTTP_FILTER
    match:
      context: GATEWAY
      listener:
        filterChain:
          filter:
            name: envoy.filters.network.http_connection_manager
            subFilter:
              name: envoy.filters.http.router
    patch:
      operation: INSERT_BEFORE
      value:
        name: envoy.filters.http.ext_proc
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.http.ext_proc.v3.ExternalProcessor
          failure_mode_allow: true
          processing_mode:
            request_header_mode: SKIP
            response_header_mode: SKIP
          grpc_service:
            envoy_grpc:
              cluster_name: $(cluster_of referenced)
YAML

# ---------------------------------------------------------------------------
# 3. Flag off: the gateway gets every Service
# ---------------------------------------------------------------------------
wait_cluster present "$(cluster_of "bulk-${BULK_COUNT}" "${BULK_NS}")"
expect_cluster present "$(cluster_of routed)"
expect_cluster present "$(cluster_of unrouted)"
expect_cluster present "$(cluster_of referenced)"
for _ in $(seq 1 12); do
  gw_admin 'config_dump?resource=dynamic_listeners' | grep -q 'envoy.filters.http.ext_proc' && break
  sleep 5
done
expect_ext_proc_in_listener
ACTIVE_OFF=$(active_clusters)
echo "active_clusters with the flag off: ${ACTIVE_OFF}"

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
echo "active_clusters with the flag on: ${ACTIVE_ON}"
if [ $((ACTIVE_OFF - ACTIVE_ON)) -lt "${BULK_COUNT}" ]; then
  fail "active_clusters: expected a drop of at least ${BULK_COUNT}, got ${ACTIVE_OFF} -> ${ACTIVE_ON}"
fi
echo "OK: active_clusters dropped from ${ACTIVE_OFF} to ${ACTIVE_ON}"

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
#    deleting the route removes it
# ---------------------------------------------------------------------------
kubectl create service clusterip late --tcp=80:8080 -n "${NS}"
apply_route late late /late

wait_cluster present "$(cluster_of late)"

kubectl delete httproute late -n "${NS}"
wait_cluster absent "$(cluster_of late)"
expect_cluster present "$(cluster_of routed)"
expect_cluster present "$(cluster_of referenced)"
expect_traffic
