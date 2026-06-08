#!/usr/bin/env bash
set -eux

# ---------------------------------------------------------------------------
# Istio dual-stack test (dual-stack cluster only).
#
# Proves that the ISTIO_DUAL_STACK feature flag turns on IPv6 across BOTH Istio
# data planes on a dual-stack cluster:
#
#   * Gateway (Envoy, north-south): dns_lookup_family flips V4_ONLY -> a
#     dual-capable family (e.g. V4_PREFERRED), IPv6 traffic through the gateway
#     goes from refused to working, and IPv4 keeps working.
#   * ztunnel (ambient, east-west): the HBONE listener (15008) starts binding
#     IPv6, IPv6 pod-to-pod traffic works, and IPv4 keeps working.
#
# Everything is toggled with a single helm upgrade that sets all three knobs
# together (istiod env + proxyMetadata + ztunnel env), so istiod restarts once
# and both data planes reconcile.
#
# REQUIRE_DUAL_STACK=true (set by CI on the dual-stack cluster) makes a missing
# IPv6 path a hard failure instead of a skip.
# ---------------------------------------------------------------------------

REQUIRE_DUAL_STACK="${REQUIRE_DUAL_STACK:-false}"

GW_NAME=dual-stack-gw
AMBIENT_NS=dual-stack-ambient
DNS_PROBE_HOST=dns-probe.dual-stack.test
DNS_PROBE_CLUSTER="outbound|80||${DNS_PROBE_HOST}"

cleanup() {
  kubectl delete httproute dual-stack-backend -n default --ignore-not-found
  kubectl delete gateway "${GW_NAME}" -n "${ISTIO_NAMESPACE}" --ignore-not-found
  kubectl delete service dual-stack-backend -n default --ignore-not-found
  kubectl delete deployment dual-stack-backend -n default --ignore-not-found
  kubectl delete pod dual-stack-client -n default --ignore-not-found
  kubectl delete serviceentry dual-stack-dns-probe -n default --ignore-not-found
  kubectl delete namespace "${AMBIENT_NS}" --ignore-not-found
}
trap cleanup EXIT

# =========================== gateway helpers ===============================
gw_pod() {
  kubectl get pod -n "${ISTIO_NAMESPACE}" -l "gateway.networking.k8s.io/gateway-name=${GW_NAME}" \
    -o jsonpath='{.items[0].metadata.name}'
}

istiod_dual_stack_val() {
  kubectl get deployment istiod -n "${ISTIO_NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="discovery")].env[?(@.name=="ISTIO_DUAL_STACK")].value}'
}

gw_dual_stack_val() {
  local pod="$1"
  kubectl get pod "${pod}" -n "${ISTIO_NAMESPACE}" \
    -o jsonpath='{.spec.containers[?(@.name=="istio-proxy")].env}' \
  | jq -r '.[] | select(.name=="ISTIO_DUAL_STACK") | .value'
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
  name: dual-stack-backend
  namespace: default
spec:
  parentRefs:
  - name: ${GW_NAME}
    namespace: ${ISTIO_NAMESPACE}
  rules:
  - backendRefs:
    - name: dual-stack-backend
      port: 80
EOF
  local status=""
  for i in $(seq 1 24); do
    status=$(kubectl get httproute dual-stack-backend -n default \
      -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
    [ "${status}" = "True" ] && break
    echo "Waiting for HTTPRoute to be accepted (attempt ${i}/24)..."
    sleep 5
  done
  if [ "${status}" != "True" ]; then
    kubectl get httproute dual-stack-backend -n default -o yaml
    fail "HTTPRoute not accepted"
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

apply_dns_probe() {
  kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: dual-stack-dns-probe
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

is_dual_dns_family() {
  case "$1" in
    V4_PREFERRED|V6_PREFERRED|ALL|AUTO) return 0 ;;
    *) return 1 ;;
  esac
}

# HTTP GET to the gateway clusterIP from the in-cluster client pod.
gw_http_ok() {
  local ip="$1" url
  case "${ip}" in
    *:*) url="http://[${ip}]:80/get" ;;
    *)   url="http://${ip}:80/get" ;;
  esac
  kubectl exec -n default dual-stack-client -- curl -sf --max-time 10 "${url}" >/dev/null
}

gw_wait_http_ok() {  # ip label
  local ip="$1" label="$2"
  for i in $(seq 1 12); do
    gw_http_ok "${ip}" && { echo "OK: ${label} works"; return 0; }
    echo "Attempt ${i}: waiting for ${label}..."
    sleep 5
  done
  fail "${label} failed"
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

# =========================== ztunnel helpers ===============================
ztunnel_pod() {
  kubectl get pod -n "${ISTIO_NAMESPACE}" -l app=ztunnel \
    -o jsonpath='{.items[0].metadata.name}'
}

ztunnel_dual_stack_val() {
  kubectl get daemonset ztunnel -n "${ISTIO_NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="istio-proxy")].env}' \
  | jq -r '.[] | select(.name=="ISTIO_DUAL_STACK") | .value'
}

# IPv6 HBONE listener on port 15008 (0x3AB8) in /proc/net/tcp6.
ztunnel_ipv6_hbone() {
  kubectl exec -n "${ISTIO_NAMESPACE}" "$(ztunnel_pod)" -- \
    cat /proc/net/tcp6 2>/dev/null | awk '{print $2}' | grep -i '3AB8$' || true
}

# curl from the ambient client to host:8080, retried. $1=curl family flag (-4/-6),
# $2=host (bracketed for IPv6), $3=label.
ambient_wait() {
  local flag="$1" host="$2" label="$3"
  for i in $(seq 1 12); do
    kubectl exec -n "${AMBIENT_NS}" client -- \
      curl -sf --max-time 10 "${flag}" "http://${host}:8080/get" >/dev/null 2>&1 \
      && { echo "OK: ${label} works"; return 0; }
    echo "Attempt ${i}: waiting for ${label}..."
    sleep 5
  done
  fail "${label} failed"
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

# ===========================================================================
# 1. Defaults: ISTIO_DUAL_STACK=false everywhere
# ===========================================================================
DS=$(istiod_dual_stack_val)
[ "${DS}" = "false" ] || fail "istiod ISTIO_DUAL_STACK: expected 'false' default, got '${DS}'"
DS=$(ztunnel_dual_stack_val)
[ "${DS}" = "false" ] || fail "ztunnel ISTIO_DUAL_STACK: expected 'false' default, got '${DS}'"
echo "OK: ISTIO_DUAL_STACK=false (default) on istiod and ztunnel"

# ===========================================================================
# 2. Deploy gateway (north-south) + ambient (east-west) workloads
# ===========================================================================
# --- gateway side ---
kubectl create deployment dual-stack-backend \
  --image=mccutchen/go-httpbin:v2.15.0 --port=8080 -n default
kubectl expose deployment dual-stack-backend --port=80 --target-port=8080 -n default
kubectl rollout status deployment/dual-stack-backend -n default --timeout=120s

kubectl run dual-stack-client \
  --image=curlimages/curl:8.5.0 --restart=Never -n default -- sleep 600
kubectl wait pod/dual-stack-client -n default --for=condition=Ready --timeout=60s

apply_gateway
apply_httproute
apply_dns_probe

GW_POD=$(gw_pod)
GW_DS=$(gw_dual_stack_val "${GW_POD}")
[ "${GW_DS}" = "false" ] || fail "gateway pod ISTIO_DUAL_STACK: expected 'false', got '${GW_DS}'"
gw_pod_ips "${GW_POD}"
echo "Gateway pod IPs: v4='${GW_V4}' v6='${GW_V6}'"
[ -n "${GW_V6}" ] || fail "gateway pod has no IPv6 address on a dual-stack cluster"

# --- ambient side ---
kubectl create namespace "${AMBIENT_NS}"
kubectl label namespace "${AMBIENT_NS}" istio.io/dataplane-mode=ambient
kubectl create deployment server \
  --image=mccutchen/go-httpbin:v2.15.0 --port=8080 -n "${AMBIENT_NS}"
kubectl expose deployment server --port=80 --target-port=8080 -n "${AMBIENT_NS}"
kubectl run client \
  --image=curlimages/curl:8.5.0 --restart=Never -n "${AMBIENT_NS}" -- sleep 600
kubectl rollout status deployment/server -n "${AMBIENT_NS}" --timeout=120s
kubectl wait pod/client -n "${AMBIENT_NS}" --for=condition=Ready --timeout=60s

SERVER_V4=$(kubectl get pod -n "${AMBIENT_NS}" -l app=server -o jsonpath='{.items[0].status.podIP}')
SERVER_V6=$(kubectl get pod -n "${AMBIENT_NS}" -l app=server -o jsonpath='{.items[0].status.podIPs[1].ip}')
echo "Ambient server pod IPs: v4='${SERVER_V4}' v6='${SERVER_V6}'"
[ -n "${SERVER_V6}" ] || fail "ambient server pod has no IPv6 address on a dual-stack cluster"

# ===========================================================================
# 3. Baseline with flag OFF
# ===========================================================================
# Gateway: dns_lookup_family V4_ONLY, IPv4 works, IPv6 refused.
DLF=$(gw_dns_lookup_family "${GW_POD}")
echo "Gateway Envoy dns_lookup_family (flag OFF) = ${DLF:-<not found>}"
[ -n "${DLF}" ] || fail "DNS probe cluster ${DNS_PROBE_CLUSTER} not found"
[ "${DLF}" = "V4_ONLY" ] || fail "expected dns_lookup_family V4_ONLY with flag off, got '${DLF}'"
echo "OK: gateway dns_lookup_family=V4_ONLY (flag off)"
gw_wait_http_ok "${GW_V4}" "gateway IPv4 (flag OFF)"
gw_expect_http_fail "${GW_V6}" "gateway IPv6 (flag OFF)"

# ztunnel: IPv4 east-west works, no IPv6 HBONE listener.
ambient_wait "-4" "${SERVER_V4}" "ambient IPv4 (flag OFF)"
HB=$(ztunnel_ipv6_hbone)
[ -z "${HB}" ] || fail "ztunnel has IPv6 HBONE listener (15008) with flag off — expected none"
echo "OK: no IPv6 HBONE listener on ztunnel (flag off)"

# ===========================================================================
# 4. Enable ISTIO_DUAL_STACK on all data planes at once
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

DS=$(istiod_dual_stack_val)
[ "${DS}" = "true" ] || fail "istiod ISTIO_DUAL_STACK: expected 'true', got '${DS}'"
DS=$(ztunnel_dual_stack_val)
[ "${DS}" = "true" ] || fail "ztunnel ISTIO_DUAL_STACK: expected 'true', got '${DS}'"
echo "OK: ISTIO_DUAL_STACK=true on istiod and ztunnel"

# Reconcile the gateway Deployment; recreate as a fallback.
kubectl rollout status "deployment/${GW_NAME}-istio" -n "${ISTIO_NAMESPACE}" --timeout=120s
GW_POD=$(gw_pod)
GW_DS=$(gw_dual_stack_val "${GW_POD}")
if [ "${GW_DS}" != "true" ]; then
  echo "Gateway Deployment was not auto-reconciled — recreating Gateway..."
  recreate_gateway
  GW_POD=$(gw_pod)
  GW_DS=$(gw_dual_stack_val "${GW_POD}")
fi
[ "${GW_DS}" = "true" ] || fail "gateway pod ISTIO_DUAL_STACK: expected 'true', got '${GW_DS}'"
gw_pod_ips "${GW_POD}"
echo "OK: gateway pod ISTIO_DUAL_STACK=true (pod IPs v4='${GW_V4}' v6='${GW_V6}')"

# ===========================================================================
# 5. Verify IPv6 now works on both data planes (IPv4 still works)
# ===========================================================================
# --- gateway ---
DLF=$(gw_dns_lookup_family "${GW_POD}")
echo "Gateway Envoy dns_lookup_family (flag ON) = ${DLF:-<not found>}"
[ -n "${DLF}" ] || fail "DNS probe cluster ${DNS_PROBE_CLUSTER} not found"
is_dual_dns_family "${DLF}" || fail "expected a dual-capable dns_lookup_family with flag on, got '${DLF}'"
echo "OK: gateway dns_lookup_family=${DLF} (dual-capable, was V4_ONLY when off)"
gw_wait_http_ok "${GW_V4}" "gateway IPv4 (flag ON)"
gw_wait_http_ok "${GW_V6}" "gateway IPv6 (flag ON)"

# --- ztunnel ---
HB=""
for i in $(seq 1 6); do
  HB=$(ztunnel_ipv6_hbone)
  [ -n "${HB}" ] && break
  echo "Attempt ${i}: waiting for ztunnel IPv6 HBONE listener..."
  sleep 5
done
[ -n "${HB}" ] || fail "ztunnel IPv6 HBONE listener (15008) not found with flag on"
echo "OK: ztunnel HBONE listening on IPv6 (flag on)"
ambient_wait "-4" "${SERVER_V4}" "ambient IPv4 (flag ON)"
ambient_wait "-6" "[${SERVER_V6}]" "ambient IPv6 (flag ON)"

# ===========================================================================
# 6. Restore defaults
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
