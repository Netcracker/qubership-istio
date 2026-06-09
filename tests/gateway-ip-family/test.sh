#!/usr/bin/env bash
set -eux

# ---------------------------------------------------------------------------
# Istio IP family on a SINGLE-STACK cluster (gateway + ztunnel).
#
# On a single-stack cluster Istio reflects the one available IP family with no
# ISTIO_DUAL_STACK needed — there is no second stack to gate. This is verified
# on BOTH data planes:
#
#   * Gateway (Envoy, north-south): dns_lookup_family follows the cluster family
#     (ipv4 -> V4_ONLY, ipv6 -> V6_ONLY) and a request through the gateway works.
#   * ztunnel (ambient, east-west): pod-to-pod traffic works over the cluster's
#     single family. (ztunnel is distroless with no shell, so it is verified by
#     connectivity rather than by inspecting config.)
#
# The dual-stack case (where ISTIO_DUAL_STACK gates IPv6 on both planes) is
# covered by the istio-dual-stack test.
#
# dns_lookup_family is read from the gateway Envoy via a DNS-resolved
# ServiceEntry probe.
# ---------------------------------------------------------------------------

GW_NAME=ip-family-gw
BACKEND_NAME=ip-family-backend
DNS_PROBE_NAME=ip-family-dns-probe
DNS_PROBE_HOST=dns-probe.ip-family.test
DNS_PROBE_CLUSTER="outbound|80||${DNS_PROBE_HOST}"
CLIENT_POD=ip-family-client
AMBIENT_NS=ip-family-ambient

# Shared helpers (gw_pod, apply_httproute, apply_dns_probe, gw_dns_lookup_family,
# gw_http_ok, gw_wait_http_ok, apply_ambient_workloads, ambient_wait).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/gateway.sh"

cleanup() {
  kubectl delete httproute "${BACKEND_NAME}" -n default --ignore-not-found
  kubectl delete gateway "${GW_NAME}" -n "${ISTIO_NAMESPACE}" --ignore-not-found
  kubectl delete service "${BACKEND_NAME}" -n default --ignore-not-found
  kubectl delete deployment "${BACKEND_NAME}" -n default --ignore-not-found
  kubectl delete pod "${CLIENT_POD}" -n default --ignore-not-found
  kubectl delete serviceentry "${DNS_PROBE_NAME}" -n default --ignore-not-found
  kubectl delete namespace "${AMBIENT_NS}" --ignore-not-found
}
trap cleanup EXIT

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

# ===========================================================================
# Setup
# ===========================================================================
kubectl create deployment "${BACKEND_NAME}" \
  --image=mccutchen/go-httpbin:v2.15.0 --port=8080 -n default
kubectl expose deployment "${BACKEND_NAME}" --port=80 --target-port=8080 -n default
kubectl rollout status "deployment/${BACKEND_NAME}" -n default --timeout=120s

kubectl run "${CLIENT_POD}" \
  --image=curlimages/curl:8.5.0 --restart=Never -n default -- sleep 600
kubectl wait "pod/${CLIENT_POD}" -n default --for=condition=Ready --timeout=60s

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

# --- ambient (ztunnel) workloads for the east-west check ---
apply_ambient_workloads
SERVER_IP=$(kubectl get pod -n "${AMBIENT_NS}" -l app=server -o jsonpath='{.items[0].status.podIP}')
echo "Ambient server pod IP: '${SERVER_IP}'"
[ -n "${SERVER_IP}" ] || fail "ambient server pod has no IP"

DLF=$(gw_dns_lookup_family "${GW_POD}")
echo "Gateway Envoy dns_lookup_family = ${DLF:-<cluster not found>}"
[ -n "${DLF}" ] || fail "DNS probe cluster ${DNS_PROBE_CLUSTER} not found in gateway Envoy config"

if [ -n "${GW_V6}" ]; then
  # --- Single-stack IPv6 ---
  [ "${DLF}" = "V6_ONLY" ] || fail "expected dns_lookup_family V6_ONLY on IPv6 cluster, got '${DLF}'"
  echo "OK: dns_lookup_family=V6_ONLY (auto-detected, no ISTIO_DUAL_STACK)"
  gw_wait_http_ok "${GW_V6}" "IPv6 request through gateway"
  ambient_wait "-6" "[${SERVER_IP}]" "IPv6 pod-to-pod through ztunnel"
else
  # --- Single-stack IPv4 ---
  [ "${DLF}" = "V4_ONLY" ] || fail "expected dns_lookup_family V4_ONLY on IPv4 cluster, got '${DLF}'"
  echo "OK: dns_lookup_family=V4_ONLY (auto-detected, no ISTIO_DUAL_STACK)"
  gw_wait_http_ok "${GW_V4}" "IPv4 request through gateway"
  ambient_wait "-4" "${SERVER_IP}" "IPv4 pod-to-pod through ztunnel"
fi

echo "gateway-ip-family passed"
