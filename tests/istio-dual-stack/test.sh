#!/usr/bin/env bash
set -eux

# ---------------------------------------------------------------------------
# Istio dual-stack test (dual-stack cluster only).
#
# Checks that the ISTIO_DUAL_STACK feature flag turns on IPv6 across BOTH Istio
# data planes on a dual-stack cluster:
#
#   * Gateway (Envoy, north-south): dns_lookup_family flips V4_ONLY -> ALL,
#     IPv6 traffic through the gateway goes from refused to working, and IPv4
#     keeps working.
#   * ztunnel (ambient, east-west): IPv6 pod-to-pod traffic through the mesh
#     starts working, and IPv4 keeps working.
#
# Scenario:
#   1. Skip unless the cluster is dual-stack (REQUIRE_DUAL_STACK=true, set by CI
#      on the dual-stack cluster, turns a missing IPv6 path into a hard failure).
#   2. Deploy a gateway (north-south) and an ambient namespace with a
#      server + client (east-west).
#   3. Baseline, flag OFF: gateway dns_lookup_family=V4_ONLY (IPv4 works, IPv6
#      refused); ztunnel IPv4 east-west works.
#   4. Enable ISTIO_DUAL_STACK on istiod + proxies + ztunnel via one helm upgrade.
#   5. Verify IPv6 now works on both data planes and IPv4 still works.
#   6. Restore ISTIO_DUAL_STACK to false.
# ---------------------------------------------------------------------------

REQUIRE_DUAL_STACK="${REQUIRE_DUAL_STACK:-false}"

GW_NAME=dual-stack-gw
BACKEND_NAME=dual-stack-backend
DNS_PROBE_NAME=dual-stack-dns-probe
AMBIENT_NS=dual-stack-ambient
DNS_PROBE_HOST=dns-probe.dual-stack.test
DNS_PROBE_CLUSTER="outbound|80||${DNS_PROBE_HOST}"
CLIENT_POD=dual-stack-client

# Shared gateway helpers (gw_pod, apply_httproute, apply_dns_probe,
# gw_dns_lookup_family, gw_http_ok, gw_wait_http_ok).
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

# =========================== gateway helpers ===============================
dump_gw_diag() {
  echo "===== gateway diagnostics ====="
  kubectl get gateway "${GW_NAME}" -n "${ISTIO_NAMESPACE}" -o yaml || true
  kubectl get deploy,po,svc,endpointslice -n "${ISTIO_NAMESPACE}" \
    -l "gateway.networking.k8s.io/gateway-name=${GW_NAME}" -o wide || true
  kubectl describe pod -n "${ISTIO_NAMESPACE}" \
    -l "gateway.networking.k8s.io/gateway-name=${GW_NAME}" || true
  kubectl get events -n "${ISTIO_NAMESPACE}" --sort-by=.lastTimestamp 2>/dev/null | tail -30 || true
  echo "===== end diagnostics ====="
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
  # Wait for istiod to create the managed Deployment.
  for i in $(seq 1 24); do
    kubectl get deploy "${GW_NAME}-istio" -n "${ISTIO_NAMESPACE}" >/dev/null 2>&1 && break
    echo "Waiting for gateway Deployment to appear (attempt ${i}/24)..."
    sleep 5
  done
  # Pods Ready first (this is what makes the Service get endpoints and lets the
  # gateway's address be assigned → Programmed).
  if ! kubectl rollout status "deployment/${GW_NAME}-istio" -n "${ISTIO_NAMESPACE}" --timeout=240s; then
    dump_gw_diag
    fail "gateway ${GW_NAME} Deployment did not become Ready"
  fi
  if ! kubectl wait gateway/"${GW_NAME}" -n "${ISTIO_NAMESPACE}" --for=condition=Programmed --timeout=120s; then
    dump_gw_diag
    fail "gateway ${GW_NAME} not Programmed"
  fi
}

recreate_gateway() {
  kubectl delete gateway "${GW_NAME}" -n "${ISTIO_NAMESPACE}" --ignore-not-found
  for i in $(seq 1 12); do
    kubectl get deployment "${GW_NAME}-istio" -n "${ISTIO_NAMESPACE}" 2>/dev/null || break
    echo "Waiting for old gateway Deployment to be garbage collected (attempt ${i}/12)..."
    sleep 5
  done
  apply_gateway
  apply_httproute
}

is_dual_capable_dns_family() {
  case "$1" in
    ALL) return 0 ;;
    *) return 1 ;;
  esac
}

gw_expect_http_fail() {  # ip label
  local ip="$1" label="$2"
  for i in 1 2 3; do
    if gw_http_ok "${ip}"; then
      fail "${label} unexpectedly succeeded"
    fi
    echo "Confirm ${i}/3: ${label} refused (expected)"
    sleep 2
  done
  echo "OK: ${label} is unreachable (as expected)"
}

# Sets GW_V4 / GW_V6 from the gateway POD IPs. We target the pod directly rather
# than the gateway Service because Istio's auto-created Service is SingleStack
# (no IPv6 clusterIP on a dual-stack cluster), whereas pods get dual IPs. Hitting
# podIP:80 exercises the Envoy listener's IP family directly, which is exactly
# what ISTIO_DUAL_STACK changes.
gw_pod_ips() {  # arg: pod name
  local pod="$1" ips
  ips=$(kubectl get pod "${pod}" -n "${ISTIO_NAMESPACE}" -o jsonpath='{.status.podIPs[*].ip}')
  GW_V4=""
  GW_V6=""
  for ip in ${ips}; do
    case "${ip}" in
      *:*) GW_V6="${ip}" ;;
      *)   GW_V4="${ip}" ;;
    esac
  done
}

# ===========================================================================
# Guard: this test is meaningful only on a dual-stack cluster.
# Detect via node podCIDRs — the kubernetes Service is SingleStack and would
# show only one family even on a dual-stack cluster.
# ===========================================================================
NODE_CIDRS=$(kubectl get nodes -o jsonpath='{range .items[*]}{.spec.podCIDRs[*]}{" "}{end}')
HAS_V4=false
HAS_V6=false
for c in ${NODE_CIDRS}; do
  case "${c}" in *:*) HAS_V6=true ;; *) HAS_V4=true ;; esac
done
if [ "${HAS_V4}" != "true" ] || [ "${HAS_V6}" != "true" ]; then
  if [ "${REQUIRE_DUAL_STACK}" = "true" ]; then
    fail "REQUIRE_DUAL_STACK=true but cluster is not dual-stack (node podCIDRs: ${NODE_CIDRS})"
  fi
  echo "Cluster is not dual-stack (node podCIDRs: ${NODE_CIDRS}) — skipping istio-dual-stack test"
  exit 0
fi
echo "OK: dual-stack cluster (node podCIDRs: ${NODE_CIDRS})"

# Ensure istiod is fully up before creating Gateways — creating a Gateway while
# istiod's controllers are still starting can leave the managed Deployment in a
# half-reconciled state (AddressNotAssigned / no endpoints).
kubectl rollout status deployment/istiod -n "${ISTIO_NAMESPACE}" --timeout=180s
kubectl wait --for=condition=Available deployment/istiod -n "${ISTIO_NAMESPACE}" --timeout=180s

# ===========================================================================
# 1. Deploy gateway (north-south) + ambient (east-west) workloads
# ===========================================================================
# --- gateway side ---
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
gw_pod_ips "${GW_POD}"
echo "Gateway pod IPs: v4='${GW_V4}' v6='${GW_V6}'"
[ -n "${GW_V6}" ] || fail "gateway pod has no IPv6 address on a dual-stack cluster"

# --- ambient side ---
apply_ambient_workloads

SERVER_V4=$(kubectl get pod -n "${AMBIENT_NS}" -l app=server -o jsonpath='{.items[0].status.podIP}')
SERVER_V6=$(kubectl get pod -n "${AMBIENT_NS}" -l app=server -o jsonpath='{.items[0].status.podIPs[1].ip}')
echo "Ambient server pod IPs: v4='${SERVER_V4}' v6='${SERVER_V6}'"
[ -n "${SERVER_V6}" ] || fail "ambient server pod has no IPv6 address on a dual-stack cluster"

# ===========================================================================
# 2. Baseline with flag OFF
# ===========================================================================
# Gateway: dns_lookup_family V4_ONLY, IPv4 works, IPv6 refused.
DLF=$(gw_dns_lookup_family "${GW_POD}")
echo "Gateway Envoy dns_lookup_family (flag OFF) = ${DLF:-<not found>}"
[ -n "${DLF}" ] || fail "DNS probe cluster ${DNS_PROBE_CLUSTER} not found"
[ "${DLF}" = "V4_ONLY" ] || fail "expected dns_lookup_family V4_ONLY with flag off, got '${DLF}'"
echo "OK: gateway dns_lookup_family=V4_ONLY (flag off)"
gw_wait_http_ok "${GW_V4}" "gateway IPv4 (flag OFF)"
gw_expect_http_fail "${GW_V6}" "gateway IPv6 (flag OFF)"

# ztunnel: IPv4 east-west works as a baseline.
ambient_wait "-4" "${SERVER_V4}" "ambient IPv4 (flag OFF)"

# ===========================================================================
# 3. Enable ISTIO_DUAL_STACK on all data planes at once
# ===========================================================================
helm upgrade "${HELM_RELEASE}" "${HELM_CHART_PATH}" \
  --namespace "${ISTIO_NAMESPACE}" \
  --timeout 3m \
  --wait \
  --reuse-values \
  --set 'istiod.env.ISTIO_DUAL_STACK=true' \
  --set-string 'istiod.meshConfig.defaultConfig.proxyMetadata.ISTIO_DUAL_STACK=true' \
  --set 'ztunnel.env.ISTIO_DUAL_STACK=true'
kubectl rollout status deployment/istiod -n "${ISTIO_NAMESPACE}" --timeout=120s
kubectl rollout status daemonset/ztunnel -n "${ISTIO_NAMESPACE}" --timeout=120s

# Wait for istiod to reconcile the gateway Deployment with the new dual-stack
# config; recreate as a fallback if the gateway is still operating single-stack.
# dns_lookup_family is the behavioural signal that the gateway actually went
# dual (V4_ONLY -> a dual-capable family), so we key the fallback off it.
kubectl rollout status "deployment/${GW_NAME}-istio" -n "${ISTIO_NAMESPACE}" --timeout=240s || true
GW_POD=$(gw_pod)
DLF=$(gw_dns_lookup_family "${GW_POD}")
if ! is_dual_capable_dns_family "${DLF}"; then
  echo "Gateway still single-stack (dns_lookup_family=${DLF:-<none>}) — recreating Gateway..."
  recreate_gateway
  GW_POD=$(gw_pod)
  DLF=$(gw_dns_lookup_family "${GW_POD}")
fi
gw_pod_ips "${GW_POD}"

# ===========================================================================
# 4. Verify IPv6 now works on both data planes (IPv4 still works)
# ===========================================================================
# --- gateway ---
echo "Gateway Envoy dns_lookup_family (flag ON) = ${DLF:-<not found>}"
[ -n "${DLF}" ] || fail "DNS probe cluster ${DNS_PROBE_CLUSTER} not found"
is_dual_capable_dns_family "${DLF}" || fail "expected a dual-capable dns_lookup_family with flag on, got '${DLF}'"
echo "OK: gateway dns_lookup_family=${DLF} (dual-capable, was V4_ONLY when off)"
gw_wait_http_ok "${GW_V4}" "gateway IPv4 (flag ON)"
gw_wait_http_ok "${GW_V6}" "gateway IPv6 (flag ON)"

# --- ztunnel: IPv4 still works and IPv6 pod-to-pod now works through ztunnel ---
ambient_wait "-4" "${SERVER_V4}" "ambient IPv4 (flag ON)"
ambient_wait "-6" "[${SERVER_V6}]" "ambient IPv6 (flag ON)"

# ===========================================================================
# 5. Restore defaults
# ===========================================================================
helm upgrade "${HELM_RELEASE}" "${HELM_CHART_PATH}" \
  --namespace "${ISTIO_NAMESPACE}" \
  --timeout 3m \
  --wait \
  --reuse-values \
  --set 'istiod.env.ISTIO_DUAL_STACK=false' \
  --set-string 'istiod.meshConfig.defaultConfig.proxyMetadata.ISTIO_DUAL_STACK=false' \
  --set 'ztunnel.env.ISTIO_DUAL_STACK=false'
kubectl rollout status deployment/istiod -n "${ISTIO_NAMESPACE}" --timeout=120s
kubectl rollout status daemonset/ztunnel -n "${ISTIO_NAMESPACE}" --timeout=120s
kubectl rollout status "deployment/${GW_NAME}-istio" -n "${ISTIO_NAMESPACE}" --timeout=120s || recreate_gateway
echo "OK: ISTIO_DUAL_STACK restored to false"

echo "istio-dual-stack passed"
