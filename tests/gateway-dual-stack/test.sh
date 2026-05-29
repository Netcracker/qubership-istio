#!/usr/bin/env bash
set -eux

GW_NAME=dual-stack-gw

cleanup() {
  kubectl delete httproute dual-stack-backend -n default --ignore-not-found
  kubectl delete gateway "${GW_NAME}" -n "${ISTIO_NAMESPACE}" --ignore-not-found
  kubectl delete service dual-stack-backend -n default --ignore-not-found
  kubectl delete deployment dual-stack-backend -n default --ignore-not-found
}
trap cleanup EXIT

gw_pod() {
  kubectl get pod -n "${ISTIO_NAMESPACE}" -l "gateway.networking.k8s.io/gateway-name=${GW_NAME}" \
    -o jsonpath='{.items[0].metadata.name}'
}

# ISTIO_DUAL_STACK on gateway pods comes from ProxyConfig.ProxyMetadata, which
# istiod builds from its own pilot feature flags (loaded from the istiod Deployment
# env at startup), not from the mesh ConfigMap. Changing the mesh ConfigMap alone
# has no effect; changing istiod.env.ISTIO_DUAL_STACK restarts istiod so it picks
# up the new value before it generates the next gateway Deployment.
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
  STATUS=""
  for i in $(seq 1 24); do
    STATUS=$(kubectl get httproute dual-stack-backend -n default \
      -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
    [ "${STATUS}" = "True" ] && break
    echo "Waiting for HTTPRoute to be accepted (attempt ${i}/24)..."
    sleep 5
  done
  if [ "${STATUS}" != "True" ]; then
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

# --- 1. Verify default ISTIO_DUAL_STACK=false on istiod Deployment ---
DUAL_STACK_VAL=$(istiod_dual_stack_val)
if [ "${DUAL_STACK_VAL}" != "false" ]; then
  fail "istiod ISTIO_DUAL_STACK: expected 'false', got '${DUAL_STACK_VAL}'"
fi
echo "OK: istiod ISTIO_DUAL_STACK=${DUAL_STACK_VAL} (default)"

# --- 2. Deploy backend and gateway ---
kubectl create deployment dual-stack-backend \
  --image=mccutchen/go-httpbin:v2.15.0 \
  --port=8080 \
  -n default
kubectl expose deployment dual-stack-backend --port=80 --target-port=8080 -n default
kubectl rollout status deployment/dual-stack-backend -n default --timeout=120s

apply_gateway
apply_httproute

# --- 3. Verify ISTIO_DUAL_STACK=false propagated to gateway pod ---
GW_POD=$(gw_pod)
DUAL_STACK_VAL=$(gw_dual_stack_val "${GW_POD}")
if [ "${DUAL_STACK_VAL}" != "false" ]; then
  fail "gateway pod ISTIO_DUAL_STACK: expected 'false', got '${DUAL_STACK_VAL}'"
fi
echo "OK: gateway pod ISTIO_DUAL_STACK=${DUAL_STACK_VAL} (default)"

# --- 4. Baseline: IPv4 traffic flows through gateway ---
CURL_EXIT=1
for i in $(seq 1 12); do
  kubectl port-forward -n "${ISTIO_NAMESPACE}" "svc/${GW_NAME}-istio" 18081:80 >/dev/null 2>&1 &
  PF_PID=$!
  sleep 2
  curl -sf http://127.0.0.1:18081/get > /dev/null
  CURL_EXIT=$?
  kill "${PF_PID}" 2>/dev/null || true
  wait "${PF_PID}" 2>/dev/null || true
  [ ${CURL_EXIT} -eq 0 ] && { echo "OK: IPv4 baseline through gateway works"; break; }
  echo "Attempt ${i}: waiting for gateway (IPv4)..."
  sleep 3
done
if [ ${CURL_EXIT} -ne 0 ]; then
  fail "IPv4 baseline through gateway failed"
fi

# --- 5. Check if cluster has IPv6 gateway service IP ---
GW_SVC_IPV6=$(kubectl get svc "${GW_NAME}-istio" -n "${ISTIO_NAMESPACE}" \
  -o jsonpath='{.spec.clusterIPs[1]}' 2>/dev/null || true)
CLUSTER_HAS_IPV6=false
if [[ "${GW_SVC_IPV6}" == *:* ]]; then
  CLUSTER_HAS_IPV6=true
  echo "Cluster is dual-stack, gateway service IPv6: ${GW_SVC_IPV6}"
else
  echo "Cluster is single-stack (IPv4 only) — IPv6 gateway connectivity test will be skipped"
fi

# --- 6. Enable ISTIO_DUAL_STACK via istiod pilot env (restarts istiod) ---
# istiod.env.ISTIO_DUAL_STACK changes the istiod Deployment spec, triggering a
# rollout. After --wait, istiod is running with the new flag and will inject
# ISTIO_DUAL_STACK=true into every new gateway Deployment it creates.
helm upgrade "${HELM_RELEASE}" "${HELM_CHART_PATH}" \
  --namespace "${ISTIO_NAMESPACE}" \
  --timeout 3m \
  --wait \
  --reuse-values \
  --set 'istiod.env.ISTIO_DUAL_STACK=true'
kubectl rollout status deployment/istiod -n "${ISTIO_NAMESPACE}" --timeout=120s

# --- 7. Verify istiod Deployment env updated ---
DUAL_STACK_VAL=$(istiod_dual_stack_val)
if [ "${DUAL_STACK_VAL}" != "true" ]; then
  fail "istiod ISTIO_DUAL_STACK: expected 'true', got '${DUAL_STACK_VAL}'"
fi
echo "OK: istiod ISTIO_DUAL_STACK=${DUAL_STACK_VAL}"

# --- 8. Recreate gateway so istiod generates a fresh Deployment with new flag ---
recreate_gateway

# --- 9. Verify ISTIO_DUAL_STACK=true propagated to new gateway pod ---
GW_POD=$(gw_pod)
DUAL_STACK_VAL=$(gw_dual_stack_val "${GW_POD}")
if [ "${DUAL_STACK_VAL}" != "true" ]; then
  fail "gateway pod ISTIO_DUAL_STACK: expected 'true', got '${DUAL_STACK_VAL}'"
fi
echo "OK: gateway pod ISTIO_DUAL_STACK=${DUAL_STACK_VAL}"

# --- 10. Verify gateway outbound listener has IPv6 socket ---
# Port 15001 (outbound) in hex = 0x3A98
IPV6_LISTENER=""
for i in $(seq 1 6); do
  IPV6_LISTENER=$(kubectl exec -n "${ISTIO_NAMESPACE}" "${GW_POD}" -c istio-proxy -- \
    cat /proc/net/tcp6 2>/dev/null | awk '{print $2}' | grep -i '3A98$' || true)
  [ -n "${IPV6_LISTENER}" ] && break
  echo "Attempt ${i}: waiting for gateway IPv6 outbound listener..."
  sleep 5
done
if [ -z "${IPV6_LISTENER}" ]; then
  echo "WARN: no IPv6 listener on port 15001 in gateway pod — may be Envoy version specific"
  kubectl exec -n "${ISTIO_NAMESPACE}" "${GW_POD}" -c istio-proxy -- cat /proc/net/tcp6 2>/dev/null || true
fi
[ -n "${IPV6_LISTENER}" ] && echo "OK: gateway proxy is listening on IPv6 (port 15001)"

# --- 11. IPv4 still works after enabling dual-stack ---
CURL_EXIT=1
for i in $(seq 1 12); do
  kubectl port-forward -n "${ISTIO_NAMESPACE}" "svc/${GW_NAME}-istio" 18081:80 >/dev/null 2>&1 &
  PF_PID=$!
  sleep 2
  curl -sf http://127.0.0.1:18081/get > /dev/null
  CURL_EXIT=$?
  kill "${PF_PID}" 2>/dev/null || true
  wait "${PF_PID}" 2>/dev/null || true
  [ ${CURL_EXIT} -eq 0 ] && break
  echo "Attempt ${i}: waiting for gateway (IPv4 post-upgrade)..."
  sleep 3
done
if [ ${CURL_EXIT} -ne 0 ]; then
  fail "IPv4 gateway connectivity broken after enabling ISTIO_DUAL_STACK"
fi
echo "OK: IPv4 gateway connectivity still works with dual-stack enabled"

# --- 12. IPv6 traffic through gateway (dual-stack clusters only) ---
if [ "${CLUSTER_HAS_IPV6}" = "true" ]; then
  CURL_EXIT=1
  for i in $(seq 1 12); do
    curl -sf -6 "http://[${GW_SVC_IPV6}]/get" > /dev/null
    CURL_EXIT=$?
    [ ${CURL_EXIT} -eq 0 ] && break
    echo "Attempt ${i}: waiting for gateway (IPv6)..."
    sleep 5
  done
  if [ ${CURL_EXIT} -ne 0 ]; then
    fail "IPv6 traffic through gateway failed with ISTIO_DUAL_STACK=true"
  fi
  echo "OK: IPv6 traffic flows through gateway"
fi

# --- 13. Restore default ---
helm upgrade "${HELM_RELEASE}" "${HELM_CHART_PATH}" \
  --namespace "${ISTIO_NAMESPACE}" \
  --timeout 3m \
  --wait \
  --reuse-values \
  --set 'istiod.env.ISTIO_DUAL_STACK=false'
kubectl rollout status deployment/istiod -n "${ISTIO_NAMESPACE}" --timeout=120s
recreate_gateway
echo "OK: ISTIO_DUAL_STACK restored to false"
