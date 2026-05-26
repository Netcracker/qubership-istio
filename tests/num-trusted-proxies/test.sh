#!/usr/bin/env bash
set -eux

cleanup() {
  kubectl delete httproute httpbin -n default --ignore-not-found
  kubectl delete gateway xff-test -n "${ISTIO_NAMESPACE}" --ignore-not-found
  kubectl delete service httpbin -n default --ignore-not-found
  kubectl delete deployment httpbin -n default --ignore-not-found
}
trap cleanup EXIT

# --- 1. Verify default numTrustedProxies=1 in mesh config ---
MESH_CONFIG=$(kubectl get configmap istio -n "${ISTIO_NAMESPACE}" -o jsonpath='{.data.mesh}')
NUM_TRUSTED=$(echo "${MESH_CONFIG}" | yq e '.defaultConfig.gatewayTopology.numTrustedProxies')
if [ "${NUM_TRUSTED}" != "1" ]; then
  echo "ERROR: numTrustedProxies expected 1, got ${NUM_TRUSTED}"
  echo "Full mesh config:"
  echo "${MESH_CONFIG}"
  fail "numTrustedProxies default value check failed"
fi
echo "OK: numTrustedProxies=${NUM_TRUSTED}"

# --- 2. Deploy XFF test resources ---
kubectl create deployment httpbin \
  --image=mccutchen/go-httpbin:v2.15.0 \
  --port=8080 \
  -n default
kubectl expose deployment httpbin --port=80 --target-port=8080 -n default

kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: xff-test
  namespace: istio-system
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

kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: httpbin
  namespace: default
spec:
  parentRefs:
  - name: xff-test
    namespace: istio-system
  rules:
  - backendRefs:
    - name: httpbin
      port: 80
EOF

# --- 3. Wait for XFF test resources ---
kubectl rollout status deployment/httpbin -n default --timeout=120s
kubectl wait gateway/xff-test -n "${ISTIO_NAMESPACE}" --for=condition=Programmed --timeout=120s
kubectl rollout status deployment/xff-test-istio -n "${ISTIO_NAMESPACE}" --timeout=120s
STATUS=""
for i in $(seq 1 24); do
  STATUS=$(kubectl get httproute httpbin -n default \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
  [ "${STATUS}" = "True" ] && { echo "HTTPRoute accepted"; break; }
  echo "Waiting for HTTPRoute to be accepted (attempt ${i}/24)..."
  sleep 5
done
if [ "${STATUS}" != "True" ]; then
  echo "ERROR: HTTPRoute not accepted after timeout"
  kubectl get httproute httpbin -n default -o yaml
  fail "HTTPRoute not accepted"
fi

# --- 4. Verify XFF behavior with numTrustedProxies=1 ---
# With numTrustedProxies=1 Envoy treats the direct peer (the port-forward
# connection) as the one trusted proxy hop, so X-Envoy-External-Address
# must equal the IP we placed in X-Forwarded-For.
kubectl port-forward -n "${ISTIO_NAMESPACE}" svc/xff-test-istio 18080:80 &
PF_PID=$!

SPOOFED_IP="203.0.113.1"
EXTERNAL_ADDR=""
HEADERS=""
for i in $(seq 1 12); do
  HEADERS=$(curl -sf -H "X-Forwarded-For: ${SPOOFED_IP}" http://127.0.0.1:18080/headers 2>/dev/null) || { sleep 5; continue; }
  EXTERNAL_ADDR=$(echo "${HEADERS}" | jq -r '
    .headers | to_entries[] |
    select(.key | ascii_downcase == "x-envoy-external-address") |
    .value[0]')
  [ "${EXTERNAL_ADDR}" = "${SPOOFED_IP}" ] && break
  echo "Attempt ${i}: X-Envoy-External-Address=${EXTERNAL_ADDR}, retrying in 5s..."
  sleep 5
done
kill ${PF_PID} 2>/dev/null || true

if [ "${EXTERNAL_ADDR}" != "${SPOOFED_IP}" ]; then
  echo "ERROR: expected X-Envoy-External-Address=${SPOOFED_IP}, got ${EXTERNAL_ADDR}"
  echo "Full response: ${HEADERS}"
  fail "XFF numTrustedProxies=1 check failed"
fi
echo "OK: X-Envoy-External-Address=${EXTERNAL_ADDR}"

# --- 5. Upgrade numTrustedProxies to 2 ---
helm upgrade "${HELM_RELEASE}" "${HELM_CHART_PATH}" \
  --namespace "${ISTIO_NAMESPACE}" \
  --timeout 3m \
  --wait \
  --reuse-values \
  --set istiod.meshConfig.defaultConfig.gatewayTopology.numTrustedProxies=2
kubectl rollout status deployment/xff-test-istio -n "${ISTIO_NAMESPACE}" --timeout=120s

# --- 6. Verify numTrustedProxies=2 in mesh config ---
MESH_CONFIG=$(kubectl get configmap istio -n "${ISTIO_NAMESPACE}" -o jsonpath='{.data.mesh}')
NUM_TRUSTED=$(echo "${MESH_CONFIG}" | yq e '.defaultConfig.gatewayTopology.numTrustedProxies')
if [ "${NUM_TRUSTED}" != "2" ]; then
  echo "ERROR: numTrustedProxies expected 2, got ${NUM_TRUSTED}"
  echo "Full mesh config:"
  echo "${MESH_CONFIG}"
  fail "numTrustedProxies=2 check failed"
fi
echo "OK: numTrustedProxies=${NUM_TRUSTED}"

# --- 7. Verify XFF behavior with numTrustedProxies=2 ---
# With numTrustedProxies=2 Envoy trusts 2 hops from the right of XFF.
# We send 2 intermediate IPs; Envoy appends the peer, making 3 entries total.
# X-Envoy-External-Address must be the leftmost (original client) IP.
# A fresh port-forward is started each iteration so a pod restart mid-loop
# (triggered by istiod pushing the new xDS config) cannot kill the whole loop.
EXTERNAL_ADDR=""
HEADERS=""
for i in $(seq 1 12); do
  kubectl port-forward -n "${ISTIO_NAMESPACE}" svc/xff-test-istio 18080:80 &
  PF_PID=$!
  sleep 2
  HEADERS=$(curl -sf -H "X-Forwarded-For: ${SPOOFED_IP}, 10.0.0.1" http://127.0.0.1:18080/headers 2>/dev/null)
  CURL_EXIT=$?
  kill ${PF_PID} 2>/dev/null || true
  wait ${PF_PID} 2>/dev/null || true
  [ ${CURL_EXIT} -ne 0 ] && { echo "Attempt ${i}: curl failed, retrying in 5s..."; sleep 3; continue; }
  EXTERNAL_ADDR=$(echo "${HEADERS}" | jq -r '
    .headers | to_entries[] |
    select(.key | ascii_downcase == "x-envoy-external-address") |
    .value[0]')
  [ "${EXTERNAL_ADDR}" = "${SPOOFED_IP}" ] && break
  echo "Attempt ${i}: X-Envoy-External-Address=${EXTERNAL_ADDR}, retrying in 5s..."
  sleep 5
done

if [ "${EXTERNAL_ADDR}" != "${SPOOFED_IP}" ]; then
  echo "ERROR: expected X-Envoy-External-Address=${SPOOFED_IP}, got ${EXTERNAL_ADDR}"
  echo "Full response: ${HEADERS}"
  fail "XFF numTrustedProxies=2 check failed"
fi
echo "OK: X-Envoy-External-Address=${EXTERNAL_ADDR}"
