#!/usr/bin/env bash
set -eux

GW_NAME=gateway-test
BACKEND_NS=gateway-test-backend

cleanup() {
  kubectl delete httproute backend-route -n "${BACKEND_NS}" --ignore-not-found
  kubectl delete httproute -n "${BACKEND_NS}" --all --ignore-not-found
  kubectl delete gateway "${GW_NAME}" -n "${ISTIO_NAMESPACE}" --ignore-not-found
  kubectl delete namespace "${BACKEND_NS}" --ignore-not-found
}
trap cleanup EXIT

gw_pod() {
  kubectl get pod -n "${ISTIO_NAMESPACE}" -l "gateway.networking.k8s.io/gateway-name=${GW_NAME}" \
    -o jsonpath='{.items[0].metadata.name}'
}

curl_gw() {
  local path="${1:-/get}"
  local extra_args="${2:-}"
  local port=18082
  kubectl port-forward -n "${ISTIO_NAMESPACE}" "svc/${GW_NAME}-istio" "${port}:80" &
  local pf_pid=$!
  sleep 2
  # shellcheck disable=SC2086
  curl -sf ${extra_args} "http://127.0.0.1:${port}${path}"
  local exit_code=$?
  kill "${pf_pid}" 2>/dev/null || true
  wait "${pf_pid}" 2>/dev/null || true
  return ${exit_code}
}

# ---------------------------------------------------------------------------
# 1. Deploy backend
# ---------------------------------------------------------------------------
kubectl create namespace "${BACKEND_NS}"

kubectl create deployment backend \
  --image=mccutchen/go-httpbin:v2.15.0 \
  --port=8080 \
  -n "${BACKEND_NS}"
kubectl expose deployment backend --port=80 --target-port=8080 -n "${BACKEND_NS}"
kubectl rollout status deployment/backend -n "${BACKEND_NS}" --timeout=120s

# ---------------------------------------------------------------------------
# 2. Create Gateway and verify provisioning
# ---------------------------------------------------------------------------
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

# Deployment and Service must exist
kubectl get deployment "${GW_NAME}-istio" -n "${ISTIO_NAMESPACE}"
kubectl get service "${GW_NAME}-istio" -n "${ISTIO_NAMESPACE}"
echo "OK: Gateway provisioned Deployment and Service"

# ---------------------------------------------------------------------------
# 3. Default service type is ClusterIP (enforced by gatewayClasses config)
# ---------------------------------------------------------------------------
SVC_TYPE=$(kubectl get svc "${GW_NAME}-istio" -n "${ISTIO_NAMESPACE}" \
  -o jsonpath='{.spec.type}')
if [ "${SVC_TYPE}" != "ClusterIP" ]; then
  fail "gateway service type: expected 'ClusterIP', got '${SVC_TYPE}'"
fi
echo "OK: gateway service type=${SVC_TYPE}"

# ---------------------------------------------------------------------------
# 4. Attach HTTPRoute and wait for acceptance
# ---------------------------------------------------------------------------
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: backend-route
  namespace: ${BACKEND_NS}
spec:
  parentRefs:
  - name: ${GW_NAME}
    namespace: ${ISTIO_NAMESPACE}
  rules:
  - backendRefs:
    - name: backend
      port: 80
EOF

STATUS=""
for i in $(seq 1 24); do
  STATUS=$(kubectl get httproute backend-route -n "${BACKEND_NS}" \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
  [ "${STATUS}" = "True" ] && break
  echo "Waiting for HTTPRoute to be accepted (attempt ${i}/24)..."
  sleep 5
done
if [ "${STATUS}" != "True" ]; then
  kubectl get httproute backend-route -n "${BACKEND_NS}" -o yaml
  fail "HTTPRoute not accepted"
fi
echo "OK: HTTPRoute accepted"

# ---------------------------------------------------------------------------
# 5. HTTP traffic flows through the gateway
# ---------------------------------------------------------------------------
RESPONSE=""
for i in $(seq 1 12); do
  RESPONSE=$(curl_gw /get 2>/dev/null) && break
  echo "Attempt ${i}: waiting for traffic through gateway..."
  sleep 5
done
if [ -z "${RESPONSE}" ]; then
  fail "HTTP traffic through gateway failed"
fi
echo "OK: HTTP traffic flows through gateway"

# ---------------------------------------------------------------------------
# 6. Path-based routing: /status/200 returns 200, /status/418 returns 418
# ---------------------------------------------------------------------------
STATUS_CODE=""
for i in $(seq 1 6); do
  STATUS_CODE=$(curl_gw /status/418 "-o /dev/null -w %{http_code}" 2>/dev/null) && break
  sleep 5
done
if [ "${STATUS_CODE}" != "418" ]; then
  fail "path routing: expected HTTP 418, got '${STATUS_CODE}'"
fi
echo "OK: path-based routing works (HTTP 418 returned)"

# ---------------------------------------------------------------------------
# 7. Request headers are forwarded to the backend
# ---------------------------------------------------------------------------
HEADERS=""
for i in $(seq 1 6); do
  HEADERS=$(curl_gw /headers "-H 'X-Test-Header: gateway-test'" 2>/dev/null) && break
  sleep 5
done
HEADER_VAL=$(echo "${HEADERS}" | jq -r '
  .headers | to_entries[] |
  select(.key | ascii_downcase == "x-test-header") |
  .value[0]' 2>/dev/null || true)
if [ "${HEADER_VAL}" != "gateway-test" ]; then
  fail "header forwarding: expected 'gateway-test', got '${HEADER_VAL}'"
fi
echo "OK: request headers forwarded through gateway"

# ---------------------------------------------------------------------------
# 8. Gateway service type can be changed to NodePort
# ---------------------------------------------------------------------------
helm upgrade "${HELM_RELEASE}" "${HELM_CHART_PATH}" \
  --namespace "${ISTIO_NAMESPACE}" \
  --timeout 3m \
  --wait \
  --reuse-values \
  --set 'istiod.gatewayClasses.istio.service.spec.type=NodePort'
kubectl rollout status "deployment/${GW_NAME}-istio" -n "${ISTIO_NAMESPACE}" --timeout=60s

SVC_TYPE=$(kubectl get svc "${GW_NAME}-istio" -n "${ISTIO_NAMESPACE}" \
  -o jsonpath='{.spec.type}')
if [ "${SVC_TYPE}" != "NodePort" ]; then
  fail "gateway service type after upgrade: expected 'NodePort', got '${SVC_TYPE}'"
fi
echo "OK: gateway service type changed to ${SVC_TYPE}"

# Traffic must still flow after service type change
RESPONSE=""
for i in $(seq 1 12); do
  RESPONSE=$(curl_gw /get 2>/dev/null) && break
  echo "Attempt ${i}: waiting for traffic after service-type change..."
  sleep 5
done
if [ -z "${RESPONSE}" ]; then
  fail "HTTP traffic through gateway failed after service type change"
fi
echo "OK: HTTP traffic still flows after service type change to NodePort"

# ---------------------------------------------------------------------------
# 9. Restore ClusterIP
# ---------------------------------------------------------------------------
helm upgrade "${HELM_RELEASE}" "${HELM_CHART_PATH}" \
  --namespace "${ISTIO_NAMESPACE}" \
  --timeout 3m \
  --wait \
  --reuse-values \
  --set 'istiod.gatewayClasses.istio.service.spec.type=ClusterIP'

SVC_TYPE=$(kubectl get svc "${GW_NAME}-istio" -n "${ISTIO_NAMESPACE}" \
  -o jsonpath='{.spec.type}')
if [ "${SVC_TYPE}" != "ClusterIP" ]; then
  fail "gateway service type restore: expected 'ClusterIP', got '${SVC_TYPE}'"
fi
echo "OK: gateway service type restored to ClusterIP"
