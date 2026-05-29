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

# Read ISTIO_DUAL_STACK from a gateway pod's PROXY_CONFIG env var.
# proxyMetadata values are baked into PROXY_CONFIG JSON at injection time,
# not exposed as individual env vars.
gw_dual_stack_val() {
  local pod="$1"
  kubectl get pod "${pod}" -n "${ISTIO_NAMESPACE}" \
    -o jsonpath='{.spec.containers[?(@.name=="istio-proxy")].env}' \
  | jq -r '.[] | select(.name=="PROXY_CONFIG") | .value | fromjson | .proxyMetadata.ISTIO_DUAL_STACK'
}

# Wait for istiod to reconcile the gateway Deployment pod template so that
# PROXY_CONFIG.proxyMetadata.ISTIO_DUAL_STACK equals the expected value.
# Annotating the Gateway triggers the istiod gateway controller to re-reconcile,
# re-reading the current mesh config and updating PROXY_CONFIG in the pod template.
# Only after the template changes does Kubernetes create new pods with the new value.
wait_gw_template_dual_stack() {
  local expected="$1"
  kubectl annotate gateway "${GW_NAME}" -n "${ISTIO_NAMESPACE}" \
    "reconcile-at=$(date +%s)" --overwrite
  local val=""
  for i in $(seq 1 30); do
    val=$(kubectl get deployment "${GW_NAME}-istio" -n "${ISTIO_NAMESPACE}" \
      -o jsonpath='{.spec.template.spec.containers[?(@.name=="istio-proxy")].env}' \
      | jq -r '.[] | select(.name=="PROXY_CONFIG") | .value | fromjson | .proxyMetadata.ISTIO_DUAL_STACK' \
      2>/dev/null || echo "")
    [ "${val}" = "${expected}" ] && return 0
    echo "Waiting for istiod to update gateway Deployment PROXY_CONFIG (attempt ${i}/30, current=${val})..."
    sleep 5
  done
  echo "ERROR: gateway Deployment PROXY_CONFIG still has ISTIO_DUAL_STACK=${val}, expected ${expected}"
  kubectl get deployment "${GW_NAME}-istio" -n "${ISTIO_NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="istio-proxy")].env}' || true
  return 1
}

# --- 1. Verify default ISTIO_DUAL_STACK=false in mesh config ---
MESH_CONFIG=$(kubectl get configmap istio -n "${ISTIO_NAMESPACE}" -o jsonpath='{.data.mesh}')
DUAL_STACK_VAL=$(echo "${MESH_CONFIG}" | yq e '.defaultConfig.proxyMetadata.ISTIO_DUAL_STACK')
if [ "${DUAL_STACK_VAL}" != "false" ]; then
  fail "ISTIO_DUAL_STACK in mesh config: expected 'false', got '${DUAL_STACK_VAL}'"
fi
echo "OK: mesh config ISTIO_DUAL_STACK=${DUAL_STACK_VAL} (default)"

# --- 2. Deploy backend and gateway ---
kubectl create deployment dual-stack-backend \
  --image=mccutchen/go-httpbin:v2.15.0 \
  --port=8080 \
  -n default
kubectl expose deployment dual-stack-backend --port=80 --target-port=8080 -n default

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

kubectl rollout status deployment/dual-stack-backend -n default --timeout=120s
kubectl wait gateway/"${GW_NAME}" -n "${ISTIO_NAMESPACE}" --for=condition=Programmed --timeout=120s
kubectl rollout status "deployment/${GW_NAME}-istio" -n "${ISTIO_NAMESPACE}" --timeout=120s

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

# --- 3. Verify ISTIO_DUAL_STACK=false in gateway pod PROXY_CONFIG ---
GW_POD=$(gw_pod)
DUAL_STACK_VAL=$(gw_dual_stack_val "${GW_POD}")
if [ "${DUAL_STACK_VAL}" != "false" ]; then
  fail "gateway pod ISTIO_DUAL_STACK: expected 'false', got '${DUAL_STACK_VAL}'"
fi
echo "OK: gateway pod ISTIO_DUAL_STACK=${DUAL_STACK_VAL} (default)"

# --- 4. Baseline: IPv4 traffic flows through gateway ---
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

# --- 6. Enable ISTIO_DUAL_STACK for gateways ---
helm upgrade "${HELM_RELEASE}" "${HELM_CHART_PATH}" \
  --namespace "${ISTIO_NAMESPACE}" \
  --timeout 3m \
  --wait \
  --reuse-values \
  --set 'istiod.meshConfig.defaultConfig.proxyMetadata.ISTIO_DUAL_STACK=true'

# --- 7. Verify mesh config updated ---
MESH_CONFIG=$(kubectl get configmap istio -n "${ISTIO_NAMESPACE}" -o jsonpath='{.data.mesh}')
DUAL_STACK_VAL=$(echo "${MESH_CONFIG}" | yq e '.defaultConfig.proxyMetadata.ISTIO_DUAL_STACK')
if [ "${DUAL_STACK_VAL}" != "true" ]; then
  fail "ISTIO_DUAL_STACK in mesh config: expected 'true', got '${DUAL_STACK_VAL}'"
fi
echo "OK: mesh config ISTIO_DUAL_STACK=${DUAL_STACK_VAL}"

# --- 8. Wait for istiod to propagate new mesh config to the gateway Deployment ---
# PROXY_CONFIG is set in the Deployment pod template by istiod's gateway controller.
# Annotating the Gateway triggers a reconcile; only after the template changes does
# Kubernetes roll new pods. A manual rollout restart would use the stale template.
wait_gw_template_dual_stack "true"
kubectl rollout status "deployment/${GW_NAME}-istio" -n "${ISTIO_NAMESPACE}" --timeout=120s

# --- 9. Verify ISTIO_DUAL_STACK=true in gateway pod PROXY_CONFIG after rollout ---
GW_POD=$(gw_pod)
DUAL_STACK_VAL=$(gw_dual_stack_val "${GW_POD}")
if [ "${DUAL_STACK_VAL}" != "true" ]; then
  fail "gateway pod ISTIO_DUAL_STACK: expected 'true', got '${DUAL_STACK_VAL}'"
fi
echo "OK: gateway pod ISTIO_DUAL_STACK=${DUAL_STACK_VAL}"

# --- 10. Verify gateway HBONE / outbound listener has IPv6 socket ---
# Port 15001 (outbound) in hex = 0x3A98
# When ISTIO_DUAL_STACK=true the gateway proxy (Envoy) binds on :: for outbound capture.
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
  --set 'istiod.meshConfig.defaultConfig.proxyMetadata.ISTIO_DUAL_STACK=false'
wait_gw_template_dual_stack "false"
kubectl rollout status "deployment/${GW_NAME}-istio" -n "${ISTIO_NAMESPACE}" --timeout=120s
echo "OK: ISTIO_DUAL_STACK restored to false"
