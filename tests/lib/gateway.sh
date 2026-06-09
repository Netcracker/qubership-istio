#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Shared helpers for the gateway IP-family tests (gateway-ip-family,
# istio-dual-stack). Sourced — not executed — by each test's test.sh.
#
# The harness (test-suite.sh) exports ISTIO_NAMESPACE and the fail() function.
# Each test must set the following before sourcing this file:
#
#   GW_NAME            name of the Gateway resource
#   BACKEND_NAME       name of the backend Deployment/Service + HTTPRoute (in ns default)
#   DNS_PROBE_NAME     name of the DNS-probe ServiceEntry (in ns default)
#   DNS_PROBE_HOST     hostname the ServiceEntry resolves
#   DNS_PROBE_CLUSTER  Envoy cluster name for the probe (outbound|80||${DNS_PROBE_HOST})
#   CLIENT_POD         name of the in-cluster curl client pod (in ns default)
#
# Tests that use the ambient helpers (apply_ambient_workloads, ambient_wait)
# must also set:
#
#   AMBIENT_NS         namespace for the ambient (ztunnel) server+client workloads
# ---------------------------------------------------------------------------

gw_pod() {
  kubectl get pod -n "${ISTIO_NAMESPACE}" -l "gateway.networking.k8s.io/gateway-name=${GW_NAME}" \
    -o jsonpath='{.items[0].metadata.name}'
}

apply_httproute() {
  kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ${BACKEND_NAME}
  namespace: default
spec:
  parentRefs:
  - name: ${GW_NAME}
    namespace: ${ISTIO_NAMESPACE}
  rules:
  - backendRefs:
    - name: ${BACKEND_NAME}
      port: 80
EOF
  local status=""
  for i in $(seq 1 24); do
    status=$(kubectl get httproute "${BACKEND_NAME}" -n default \
      -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
    [ "${status}" = "True" ] && break
    echo "Waiting for HTTPRoute to be accepted (attempt ${i}/24)..."
    sleep 5
  done
  if [ "${status}" != "True" ]; then
    kubectl get httproute "${BACKEND_NAME}" -n default -o yaml
    fail "HTTPRoute not accepted"
  fi
}

apply_dns_probe() {
  kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: ${DNS_PROBE_NAME}
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

# HTTP GET to host:80 from the in-cluster client pod (IPv6 hosts pre-bracketed).
gw_http_ok() {
  local ip="$1" url
  case "${ip}" in
    *:*) url="http://[${ip}]:80/get" ;;
    *)   url="http://${ip}:80/get" ;;
  esac
  kubectl exec -n default "${CLIENT_POD}" -- curl -sf --max-time 10 "${url}" >/dev/null
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

# =========================== ambient (ztunnel) helpers =====================
# ztunnel runs on a distroless/static image (no shell), so its IP-family
# behaviour can't be inspected from inside the pod — it is verified by actual
# pod-to-pod connectivity. The helpers below operate in ${AMBIENT_NS}.

# Create an ambient-labelled namespace with a server (httpbin) + curl client.
apply_ambient_workloads() {
  kubectl create namespace "${AMBIENT_NS}"
  kubectl label namespace "${AMBIENT_NS}" istio.io/dataplane-mode=ambient
  kubectl create deployment server \
    --image=mccutchen/go-httpbin:v2.15.0 --port=8080 -n "${AMBIENT_NS}"
  kubectl expose deployment server --port=80 --target-port=8080 -n "${AMBIENT_NS}"
  kubectl run client \
    --image=curlimages/curl:8.5.0 --restart=Never -n "${AMBIENT_NS}" -- sleep 600
  kubectl rollout status deployment/server -n "${AMBIENT_NS}" --timeout=120s
  kubectl wait pod/client -n "${AMBIENT_NS}" --for=condition=Ready --timeout=60s
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
