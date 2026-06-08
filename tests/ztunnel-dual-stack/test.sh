#!/usr/bin/env bash
set -eux

NS=dual-stack-test

# When REQUIRE_DUAL_STACK=true (set by CI, which runs on a dual-stack kind
# cluster) a missing IPv6 path is a hard failure instead of a skip. Left unset
# for local runs against single-stack clusters, where IPv6 checks are skipped.
REQUIRE_DUAL_STACK="${REQUIRE_DUAL_STACK:-false}"

cleanup() {
  kubectl delete namespace "${NS}" --ignore-not-found
}
trap cleanup EXIT

get_ztunnel_pod() {
  kubectl get pod -n "${ISTIO_NAMESPACE}" -l app=ztunnel \
    -o jsonpath='{.items[0].metadata.name}'
}

# --- 1. Verify default ISTIO_DUAL_STACK=false in ztunnel DaemonSet ---
DS_ENV=$(kubectl get daemonset ztunnel -n "${ISTIO_NAMESPACE}" \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="istio-proxy")].env}')
DUAL_STACK_VAL=$(echo "${DS_ENV}" | jq -r '.[] | select(.name=="ISTIO_DUAL_STACK") | .value')
if [ "${DUAL_STACK_VAL}" != "false" ]; then
  fail "ISTIO_DUAL_STACK: expected 'false', got '${DUAL_STACK_VAL}'"
fi
echo "OK: ISTIO_DUAL_STACK=${DUAL_STACK_VAL} (default)"

# --- 2. Deploy server and client in ambient mesh ---
kubectl create namespace "${NS}"
kubectl label namespace "${NS}" istio.io/dataplane-mode=ambient

kubectl create deployment server \
  --image=mccutchen/go-httpbin:v2.15.0 \
  --port=8080 \
  -n "${NS}"
kubectl expose deployment server --port=80 --target-port=8080 -n "${NS}"

kubectl run client \
  --image=curlimages/curl:8.5.0 \
  --restart=Never \
  -n "${NS}" \
  -- sleep 600

kubectl rollout status deployment/server -n "${NS}" --timeout=120s
kubectl wait pod/client -n "${NS}" --for=condition=Ready --timeout=60s

SERVER_IPV4=$(kubectl get pod -n "${NS}" -l app=server \
  -o jsonpath='{.items[0].status.podIP}')
echo "Server pod IPv4: ${SERVER_IPV4}"

# --- 3. Baseline: IPv4 connectivity with dual-stack disabled ---
IPV4_OK=false
for i in $(seq 1 12); do
  kubectl exec -n "${NS}" client -- curl -sf "http://${SERVER_IPV4}:8080/get" > /dev/null && IPV4_OK=true && break
  echo "Attempt ${i}: waiting for server (IPv4)..."
  sleep 5
done
if [ "${IPV4_OK}" != "true" ]; then
  fail "IPv4 baseline connectivity failed with ISTIO_DUAL_STACK=false"
fi
echo "OK: IPv4 baseline connectivity works"

# --- 4. Check if cluster has IPv6 pod IPs ---
SERVER_IPV6=$(kubectl get pod -n "${NS}" -l app=server \
  -o jsonpath='{.items[0].status.podIPs[1].ip}' 2>/dev/null || true)
CLUSTER_HAS_IPV6=false
if [[ "${SERVER_IPV6}" == *:* ]]; then
  CLUSTER_HAS_IPV6=true
  echo "Cluster is dual-stack, server IPv6: ${SERVER_IPV6}"
elif [ "${REQUIRE_DUAL_STACK}" = "true" ]; then
  kubectl get pod -n "${NS}" -l app=server -o jsonpath='{.items[0].status.podIPs}'
  fail "REQUIRE_DUAL_STACK=true but server pod has no IPv6 address — cluster is not dual-stack"
else
  echo "Cluster is single-stack (IPv4 only) — IPv6 connectivity tests will be skipped"
fi

# --- 4b. Negative proof: no IPv6 HBONE listener while dual-stack OFF ---
# The "before" half of the A/B proof; step 7 is the "after" half. Port 15008
# (HBONE, 0x3AB8) is ztunnel's tunnel listener. With ISTIO_DUAL_STACK=false
# ztunnel binds it on IPv4 only, so it cannot terminate tunneled traffic over
# IPv6 — the IPv6 socket simply does not exist yet.
#
# Note: we deliberately do NOT assert that an IPv6 *curl* fails here. In ambient
# mode, with dual-stack off istio-cni does not program ip6tables redirect rules,
# so IPv6 pod-to-pod traffic bypasses the mesh and connects directly rather than
# failing. The listener socket, by contrast, is a deterministic property of
# ztunnel's own config and is the honest signal that IPv6 tunneling is off.
if [ "${CLUSTER_HAS_IPV6}" = "true" ]; then
  ZTUNNEL_POD=$(get_ztunnel_pod)
  IPV6_HBONE_OFF=$(kubectl exec -n "${ISTIO_NAMESPACE}" "${ZTUNNEL_POD}" -- \
    cat /proc/net/tcp6 2>/dev/null | awk '{print $2}' | grep -i '3AB8$' || true)
  if [ -n "${IPV6_HBONE_OFF}" ]; then
    fail "ztunnel has an IPv6 HBONE listener (15008) with ISTIO_DUAL_STACK=false — expected none"
  fi
  echo "OK: no IPv6 HBONE listener while dual-stack off (as expected)"
fi

# --- 5. Enable ISTIO_DUAL_STACK ---
helm upgrade "${HELM_RELEASE}" "${HELM_CHART_PATH}" \
  --namespace "${ISTIO_NAMESPACE}" \
  --timeout 3m \
  --wait \
  --reuse-values \
  --set ztunnel.env.ISTIO_DUAL_STACK=true
kubectl rollout status daemonset/ztunnel -n "${ISTIO_NAMESPACE}" --timeout=120s

# --- 6. Verify property propagated to DaemonSet ---
DS_ENV=$(kubectl get daemonset ztunnel -n "${ISTIO_NAMESPACE}" \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="istio-proxy")].env}')
DUAL_STACK_VAL=$(echo "${DS_ENV}" | jq -r '.[] | select(.name=="ISTIO_DUAL_STACK") | .value')
if [ "${DUAL_STACK_VAL}" != "true" ]; then
  fail "ISTIO_DUAL_STACK: expected 'true', got '${DUAL_STACK_VAL}'"
fi
echo "OK: ISTIO_DUAL_STACK=${DUAL_STACK_VAL}"

# --- 7. Check ztunnel HBONE inbound listener is on IPv6 when dual-stack enabled ---
# Port 15008 (HBONE) should bind on :: so it accepts tunneled traffic over IPv6.
# /proc/net/tcp6 always exists and doesn't require shell utilities in the container.
# 15008 decimal = 0x3AB8
ZTUNNEL_POD=$(get_ztunnel_pod)
IPV6_HBONE=""
for i in $(seq 1 6); do
  IPV6_HBONE=$(kubectl exec -n "${ISTIO_NAMESPACE}" "${ZTUNNEL_POD}" -- \
    cat /proc/net/tcp6 2>/dev/null | awk '{print $2}' | grep -i '3AB8$' || true)
  [ -n "${IPV6_HBONE}" ] && break
  echo "Attempt ${i}: waiting for ztunnel IPv6 HBONE listener..."
  sleep 5
done
if [ -z "${IPV6_HBONE}" ]; then
  echo "ERROR: no IPv6 listener on port 15008 (HBONE) with ISTIO_DUAL_STACK=true"
  kubectl exec -n "${ISTIO_NAMESPACE}" "${ZTUNNEL_POD}" -- cat /proc/net/tcp6 2>/dev/null || true
  fail "ztunnel IPv6 HBONE listener not found"
fi
echo "OK: ztunnel HBONE port 15008 is listening on IPv6"

# --- 8. IPv4 still works after enabling dual-stack ---
IPV4_OK=false
for i in $(seq 1 12); do
  kubectl exec -n "${NS}" client -- curl -sf "http://${SERVER_IPV4}:8080/get" > /dev/null && IPV4_OK=true && break
  echo "Attempt ${i}: waiting for server (IPv4)..."
  sleep 5
done
if [ "${IPV4_OK}" != "true" ]; then
  fail "IPv4 connectivity broken after enabling ISTIO_DUAL_STACK"
fi
echo "OK: IPv4 connectivity still works with dual-stack enabled"

# --- 9. IPv6 pod-to-pod connectivity through ztunnel (dual-stack clusters only) ---
if [ "${CLUSTER_HAS_IPV6}" = "true" ]; then
  IPV6_OK=false
  for i in $(seq 1 12); do
    kubectl exec -n "${NS}" client -- \
      curl -sf -6 "http://[${SERVER_IPV6}]:8080/get" > /dev/null && IPV6_OK=true && break
    echo "Attempt ${i}: waiting for server (IPv6)..."
    sleep 5
  done
  if [ "${IPV6_OK}" != "true" ]; then
    fail "IPv6 pod-to-pod connectivity failed with ISTIO_DUAL_STACK=true"
  fi
  echo "OK: IPv6 pod-to-pod connectivity works through ztunnel"
fi

# --- 10. Restore default ---
helm upgrade "${HELM_RELEASE}" "${HELM_CHART_PATH}" \
  --namespace "${ISTIO_NAMESPACE}" \
  --timeout 3m \
  --wait \
  --reuse-values \
  --set ztunnel.env.ISTIO_DUAL_STACK=false
kubectl rollout status daemonset/ztunnel -n "${ISTIO_NAMESPACE}" --timeout=120s
echo "OK: ISTIO_DUAL_STACK restored to false"
