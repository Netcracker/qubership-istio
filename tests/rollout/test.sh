#!/usr/bin/env bash
set -eux

echo "::group::istiod deployment"
kubectl rollout status deployment/istiod -n "${ISTIO_NAMESPACE}" --timeout=120s
kubectl get deployment istiod -n "${ISTIO_NAMESPACE}" -o wide
echo "::endgroup::"

echo "::group::istio-cni-node daemonset"
kubectl rollout status daemonset/istio-cni-node -n "${ISTIO_NAMESPACE}" --timeout=120s
kubectl get daemonset istio-cni-node -n "${ISTIO_NAMESPACE}" -o wide
echo "::endgroup::"

echo "::group::ztunnel daemonset"
kubectl rollout status daemonset/ztunnel -n "${ISTIO_NAMESPACE}" --timeout=120s
kubectl get daemonset ztunnel -n "${ISTIO_NAMESPACE}" -o wide
echo "::endgroup::"

echo "::group::all pods"
kubectl get pods -n "${ISTIO_NAMESPACE}" -o wide
echo "::endgroup::"
