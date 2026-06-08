#!/usr/bin/env bash
set -eux

# ---------------------------------------------------------------------------
# Gateway dns_lookup_family on a SINGLE-STACK cluster.
#
# Istio auto-detects a single-stack cluster's IP family (no ISTIO_DUAL_STACK
# needed) and configures the Envoy gateway accordingly:
#
#   ipv4 cluster -> dns_lookup_family V4_ONLY; IPv4 works; no IPv6 path exists.
#   ipv6 cluster -> dns_lookup_family V6_ONLY; IPv6 works.
#
# The dual-stack case (where ISTIO_DUAL_STACK gates the behaviour) is covered by
# the istio-dual-stack test instead, so this test exits early on a dual cluster.
#
# dns_lookup_family is read from the gateway Envoy via a DNS-resolved
# ServiceEntry probe (the host is never resolved; only its cluster config is
# inspected).
# ---------------------------------------------------------------------------

GW_NAME=ip-family-gw
DNS_PROBE_HOST=dns-probe.ip-family.test
DNS_PROBE_CLUSTER="outbound|80||${DNS_PROBE_HOST}"

cleanup() {
  kubectl delete httproute ip-family-backend -n default --ignore-not-found
  kubectl delete gateway "${GW_NAME}" -n "${ISTIO_NAMESPACE}" --ignore-not-found
  kubectl delete service ip-family-backend -n default --ignore-not-found
  kubectl delete deployment ip-family-backend -n default --ignore-not-found
  kubectl delete pod ip-family-client -n default --ignore-not-found
  kubectl delete serviceentry ip-family-dns-probe -n default --ignore-not-found
}
trap cleanup EXIT

gw_pod() {
  kubectl get pod -n "${ISTIO_NAMESPACE}" -l "gateway.networking.k8s.io/gateway-name=${GW_NAME}" \
    -o jsonpath='{.items[0].metadata.name}'
}

apply_gateway() {
  kubectl apply -f - <<EOF
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
EOF
  kubectl wait gateway/"${GW_NAME}" -n "${ISTIO_NAMESPACE}" --for=condition=Programmed --timeout=120s
  kubectl rollout status "deployment/${GW_NAME}-istio" -n "${ISTIO_NAMESPACE}" --timeout=120s
}

apply_httproute() {
  kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ip-family-backend
  namespace: default
spec:
  parentRefs:
  - name: ${GW_NAME}
    namespace: ${ISTIO_NAMESPACE}
  rules:
  - backendRefs:
    - name: ip-family-backend
      port: 80
EOF
  local status=""
  for i in $(seq 1 24); do
    status=$(kubectl get httproute ip-family-backend -n default \
      -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
    [ "${status}" = "True" ] && break
    echo "Waiting for HTTPRoute to be accepted (attempt ${i}/24)..."
    sleep 5
  done
  if [ "${status}" != "True" ]; then
    kubectl get httproute ip-family-backend -n default -o yaml
    fail "HTTPRoute not accepted"
  fi
}

apply_dns_probe() {
  kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: ip-family-dns-probe
  namespace: default
spec:
  hosts:
  - ${DNS_PROBE_HOST}
  location: MESH_EXTERNAL
  ports:
  - number: 80
    name: http
    protocol: HTTP
  resolution: DNS
EOF
}

# Envoy omits dns_lookup_family from config_dump when it is the proto default
# (V4_ONLY), so an absent value is normalized to V4_ONLY.
gw_dns_lookup_family() {
  local pod="$1" val=""
  for _ in $(seq 1 12); do
    val=$(kubectl exec -n "${ISTIO_NAMESPACE}" "${pod}" -c istio-proxy -- \
      pilot-agent request GET config_dump 2>/dev/null \
      | jq -r --arg c "${DNS_PROBE_CLUSTER}" '
          [ .configs[]
            | select(.["@type"] | test("ClustersConfigDump"))
            | ((.dynamic_active_clusters // []) + (.static_clusters // []))[]
            | select(.cluster.name == $c)
            | (.cluster.dns_lookup_family // "V4_ONLY") ] | .[0] // empty' 2>/dev/null)
    [ -n "${val}" ] && { echo "${val}"; return 0; }
    sleep 5
  done
  echo ""
}

http_ok() {
  local ip="$1" url
  case "${ip}" in
    *:*) url="http://[${ip}]:80/get" ;;
    *)   url="http://${ip}:80/get" ;;
  esac
  kubectl exec -n default ip-family-client -- curl -sf --max-time 10 "${url}" >/dev/null
}

wait_http_ok() {  # ip label
  local ip="$1" label="$2"
  for i in $(seq 1 12); do
    http_ok "${ip}" && { echo "OK: ${label} works"; return 0; }
    echo "Attempt ${i}: waiting for ${label}..."
    sleep 5
  done
  fail "${label} failed"
}

# ===========================================================================
# Setup
# ===========================================================================
kubectl create deployment ip-family-backend \
  --image=mccutchen/go-httpbin:v2.15.0 --port=8080 -n default
kubectl expose deployment ip-family-backend --port=80 --target-port=8080 -n default
kubectl rollout status deployment/ip-family-backend -n default --timeout=120s

kubectl run ip-family-client \
  --image=curlimages/curl:8.5.0 --restart=Never -n default -- sleep 600
kubectl wait pod/ip-family-client -n default --for=condition=Ready --timeout=60s

apply_gateway
apply_httproute
apply_dns_probe
GW_POD=$(gw_pod)

# Detect the cluster IP stack from the gateway Service's clusterIPs.
CLUSTER_IPS=$(kubectl get svc "${GW_NAME}-istio" -n "${ISTIO_NAMESPACE}" \
  -o jsonpath='{.spec.clusterIPs[*]}')
GW_V4=""
GW_V6=""
for ip in ${CLUSTER_IPS}; do
  case "${ip}" in
    *:*) GW_V6="${ip}" ;;
    *)   GW_V4="${ip}" ;;
  esac
done
echo "Gateway service clusterIPs: v4='${GW_V4}' v6='${GW_V6}'"

# Dual-stack is covered by the istio-dual-stack test.
if [ -n "${GW_V4}" ] && [ -n "${GW_V6}" ]; then
  echo "Dual-stack cluster detected — dual-stack behaviour is covered by the istio-dual-stack test; nothing to do here"
  exit 0
fi

DLF=$(gw_dns_lookup_family "${GW_POD}")
echo "Gateway Envoy dns_lookup_family = ${DLF:-<cluster not found>}"
[ -n "${DLF}" ] || fail "DNS probe cluster ${DNS_PROBE_CLUSTER} not found in gateway Envoy config"

if [ -n "${GW_V6}" ]; then
  # --- Single-stack IPv6 ---
  [ "${DLF}" = "V6_ONLY" ] || fail "expected dns_lookup_family V6_ONLY on IPv6 cluster, got '${DLF}'"
  echo "OK: dns_lookup_family=V6_ONLY (auto-detected, no ISTIO_DUAL_STACK)"
  wait_http_ok "${GW_V6}" "IPv6 request through gateway"
else
  # --- Single-stack IPv4 ---
  [ "${DLF}" = "V4_ONLY" ] || fail "expected dns_lookup_family V4_ONLY on IPv4 cluster, got '${DLF}'"
  echo "OK: dns_lookup_family=V4_ONLY (auto-detected, no ISTIO_DUAL_STACK)"
  wait_http_ok "${GW_V4}" "IPv4 request through gateway"
  echo "OK: no IPv6 path on IPv4-only cluster (IPv6 does not work, as expected)"
fi

echo "gateway-ip-family passed"
