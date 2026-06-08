#!/usr/bin/env bash
set -eux

# ---------------------------------------------------------------------------
# Stack-aware gateway test.
#
# Detects the kind cluster's IP family at runtime and proves how Istio drives
# the Envoy gateway's dns_lookup_family and IPv4/IPv6 connectivity:
#
#   ipv4 cluster  -> dns_lookup_family V4_ONLY; IPv4 works; no IPv6 path exists.
#   ipv6 cluster  -> dns_lookup_family V6_ONLY; IPv6 works.
#   dual cluster  -> ISTIO_DUAL_STACK gates it. OFF: V4_ONLY + IPv6 refused.
#                    ON: V4_PREFERRED + both IPv4 and IPv6 work.
#
# Istio auto-detects single-stack v4/v6 (no flag needed). Dual-stack is the only
# case that requires ISTIO_DUAL_STACK=true — that flag is what makes istiod treat
# the proxy as dual and emit a dual-capable dns_lookup_family (the value an
# operator used to set by hand via Envoy's DNS_LOOKUP_FAMILY).
#
# dns_lookup_family is read back from the gateway Envoy via a DNS-resolved
# ServiceEntry probe; the probe host is never resolved, only its generated
# cluster config is inspected.
# ---------------------------------------------------------------------------

GW_NAME=ip-family-gw

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

# ISTIO_DUAL_STACK on gateway pods comes from ProxyConfig.ProxyMetadata, which
# istiod builds from its own pilot feature flags (loaded from the istiod
# Deployment env at startup). Changing istiod.env.ISTIO_DUAL_STACK restarts
# istiod so it picks up the new value before generating the next gateway pod.
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

# --- DNS probe: a STRICT_DNS ServiceEntry whose Envoy dns_lookup_family we read.
DNS_PROBE_HOST=dns-probe.ip-family.test
DNS_PROBE_CLUSTER="outbound|80||${DNS_PROBE_HOST}"

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

# Read Envoy dns_lookup_family for the probe cluster on a gateway pod. Envoy
# omits the field from config_dump when it equals the proto default (V4_ONLY),
# so an absent value is normalized to V4_ONLY. Retries because the cluster shows
# up only after istiod pushes the ServiceEntry.
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

# A dns_lookup_family value that lets Envoy resolve IPv6 (i.e. not IPv4-only).
is_dual_dns_family() {
  case "$1" in
    V4_PREFERRED|V6_PREFERRED|ALL|AUTO) return 0 ;;
    *) return 1 ;;
  esac
}

# HTTP GET to the gateway clusterIP from the in-cluster client pod. IPv6 literals
# are bracketed. --max-time keeps a refused/blackholed attempt from hanging.
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

expect_http_fail() {  # ip label
  local ip="$1" label="$2"
  for i in 1 2 3; do
    if http_ok "${ip}"; then
      fail "${label} unexpectedly succeeded"
    fi
    echo "Confirm ${i}/3: ${label} refused (expected)"
    sleep 2
  done
  echo "OK: ${label} is unreachable (as expected)"
}

assert_dns_family() {  # actual expected
  if [ "$1" != "$2" ]; then
    fail "Envoy dns_lookup_family: expected '$2', got '$1'"
  fi
  echo "OK: Envoy dns_lookup_family=$1"
}

# ===========================================================================
# Setup (shared by all stacks)
# ===========================================================================
kubectl create deployment ip-family-backend \
  --image=mccutchen/go-httpbin:v2.15.0 \
  --port=8080 \
  -n default
kubectl expose deployment ip-family-backend --port=80 --target-port=8080 -n default
kubectl rollout status deployment/ip-family-backend -n default --timeout=120s

kubectl run ip-family-client \
  --image=curlimages/curl:8.5.0 \
  --restart=Never \
  -n default \
  -- sleep 600
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
if [ -n "${GW_V4}" ] && [ -n "${GW_V6}" ]; then
  STACK=dual
elif [ -n "${GW_V6}" ]; then
  STACK=ipv6
else
  STACK=ipv4
fi
echo "Detected cluster IP stack: ${STACK} (v4='${GW_V4}' v6='${GW_V6}')"

# ===========================================================================
case "${STACK}" in

ipv4)
  # --- Scenario 1: IPv4-only cluster ----------------------------------------
  # Istio auto-detects IPv4; no ISTIO_DUAL_STACK needed.
  DS=$(istiod_dual_stack_val)
  [ "${DS}" = "false" ] && echo "OK: ISTIO_DUAL_STACK=${DS} (not needed for single-stack v4)"

  DLF=$(gw_dns_lookup_family "${GW_POD}")
  echo "Envoy dns_lookup_family = ${DLF:-<cluster not found>}"
  [ -n "${DLF}" ] || fail "DNS probe cluster ${DNS_PROBE_CLUSTER} not found"
  assert_dns_family "${DLF}" "V4_ONLY"

  wait_http_ok "${GW_V4}" "IPv4 request through gateway"

  # No IPv6 path exists on an IPv4-only cluster.
  if [ -n "${GW_V6}" ]; then
    fail "unexpected IPv6 clusterIP '${GW_V6}' on an IPv4-only cluster"
  fi
  echo "OK: no IPv6 path on IPv4-only cluster (IPv6 does not work, as expected)"
  ;;

ipv6)
  # --- Scenario 2: IPv6-only cluster ----------------------------------------
  # Istio auto-detects IPv6; no ISTIO_DUAL_STACK needed.
  DS=$(istiod_dual_stack_val)
  [ "${DS}" = "false" ] && echo "OK: ISTIO_DUAL_STACK=${DS} (not needed for single-stack v6)"

  DLF=$(gw_dns_lookup_family "${GW_POD}")
  echo "Envoy dns_lookup_family = ${DLF:-<cluster not found>}"
  [ -n "${DLF}" ] || fail "DNS probe cluster ${DNS_PROBE_CLUSTER} not found"
  assert_dns_family "${DLF}" "V6_ONLY"

  wait_http_ok "${GW_V6}" "IPv6 request through gateway"

  # An IPv6-only cluster has no IPv4 address to target, and V6_ONLY tells Envoy
  # to resolve AAAA records only — so there is no IPv4 leg to exercise here.
  echo "Note: IPv6-only cluster has no IPv4 clusterIP; IPv4 request is N/A under V6_ONLY"
  ;;

dual)
  # --- Scenario 3: dual-stack cluster — ISTIO_DUAL_STACK gates the behaviour --

  # 3a. Default (flag OFF): istiod auto-collapses the dual proxy to IPv4.
  DS=$(istiod_dual_stack_val)
  [ "${DS}" = "false" ] || fail "istiod ISTIO_DUAL_STACK: expected 'false' default, got '${DS}'"
  GW_DS=$(gw_dual_stack_val "${GW_POD}")
  [ "${GW_DS}" = "false" ] || fail "gateway pod ISTIO_DUAL_STACK: expected 'false', got '${GW_DS}'"
  echo "OK: ISTIO_DUAL_STACK=false (default)"

  DLF=$(gw_dns_lookup_family "${GW_POD}")
  echo "Envoy dns_lookup_family (flag OFF) = ${DLF:-<cluster not found>}"
  [ -n "${DLF}" ] || fail "DNS probe cluster ${DNS_PROBE_CLUSTER} not found"
  assert_dns_family "${DLF}" "V4_ONLY"

  wait_http_ok "${GW_V4}" "IPv4 request (flag OFF)"
  expect_http_fail "${GW_V6}" "IPv6 request (flag OFF)"

  # 3b. Enable ISTIO_DUAL_STACK (both knobs together: istiod env restarts istiod;
  # proxyMetadata carries the value into gateway pods via ProxyConfig).
  helm upgrade "${HELM_RELEASE}" "${HELM_CHART_PATH}" \
    --namespace "${ISTIO_NAMESPACE}" \
    --timeout 3m \
    --wait \
    --reuse-values \
    --set 'istiod.env.ISTIO_DUAL_STACK=true' \
    --set-string 'istiod.meshConfig.defaultConfig.proxyMetadata.ISTIO_DUAL_STACK=true'
  kubectl rollout status deployment/istiod -n "${ISTIO_NAMESPACE}" --timeout=120s

  DS=$(istiod_dual_stack_val)
  [ "${DS}" = "true" ] || fail "istiod ISTIO_DUAL_STACK: expected 'true', got '${DS}'"
  echo "OK: istiod ISTIO_DUAL_STACK=true"

  # Wait for istiod to reconcile the gateway Deployment; recreate as a fallback.
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
  echo "OK: gateway pod ISTIO_DUAL_STACK=true"

  # The gateway Service may have been recreated → re-read its clusterIPs.
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

  # 3c. dns_lookup_family now dual-capable, and both families route.
  DLF=$(gw_dns_lookup_family "${GW_POD}")
  echo "Envoy dns_lookup_family (flag ON) = ${DLF:-<cluster not found>}"
  [ -n "${DLF}" ] || fail "DNS probe cluster ${DNS_PROBE_CLUSTER} not found"
  if ! is_dual_dns_family "${DLF}"; then
    fail "Envoy dns_lookup_family is '${DLF}' with ISTIO_DUAL_STACK=true — expected a dual-capable family (e.g. V4_PREFERRED)"
  fi
  echo "OK: Envoy dns_lookup_family=${DLF} (dual-capable, was V4_ONLY when off)"

  wait_http_ok "${GW_V4}" "IPv4 request (flag ON)"
  wait_http_ok "${GW_V6}" "IPv6 request (flag ON)"

  # 3d. Restore default.
  helm upgrade "${HELM_RELEASE}" "${HELM_CHART_PATH}" \
    --namespace "${ISTIO_NAMESPACE}" \
    --timeout 3m \
    --wait \
    --reuse-values \
    --set 'istiod.env.ISTIO_DUAL_STACK=false' \
    --set-string 'istiod.meshConfig.defaultConfig.proxyMetadata.ISTIO_DUAL_STACK=false'
  kubectl rollout status deployment/istiod -n "${ISTIO_NAMESPACE}" --timeout=120s
  kubectl rollout status "deployment/${GW_NAME}-istio" -n "${ISTIO_NAMESPACE}" --timeout=120s || recreate_gateway
  echo "OK: ISTIO_DUAL_STACK restored to false"
  ;;

esac

echo "gateway-ip-family (${STACK}) passed"
