#!/usr/bin/env bash
set -euo pipefail

# Verifies the values this distribution picks for a platform, from rendered manifests only:
#   - openshift: istiod trusts ztunnel in the release namespace instead of the profile's
#     kube-system, and the Pod Security Standards hook is skipped even when enabled,
#     whether the platform is set globally or on the subcharts;
#     and the release notes say so;
#   - gke: the CNI plugin goes to /home/kubernetes/bin without a -gke cluster version,
#     also when only the cni chart sets the platform;
#   - an explicit trusted ztunnel namespace still wins, and no platform keeps the old behavior.

RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "${RENDER_DIR}"' EXIT

render() {
  local out="$1"
  shift
  helm template "${HELM_RELEASE}" "${HELM_CHART_PATH}" --namespace "${ISTIO_NAMESPACE}" "$@" > "${RENDER_DIR}/${out}.yaml"
}

# CA_TRUSTED_NODE_ACCOUNTS of the istiod container, "<namespace>/<service account>".
trusted_ztunnel() {
  yq -r 'select(.kind == "Deployment" and .metadata.name == "istiod")
    | .spec.template.spec.containers[0].env[]
    | select(.name == "CA_TRUSTED_NODE_ACCOUNTS") | .value' "${RENDER_DIR}/$1.yaml"
}

cni_bin_dir() {
  yq -r 'select(.kind == "DaemonSet" and .metadata.name == "istio-cni-node")
    | .spec.template.spec.volumes[] | select(.name == "cni-bin-dir") | .hostPath.path' "${RENDER_DIR}/$1.yaml"
}

patch_pss_count() {
  grep -c 'name: istio-patch-pss$' "${RENDER_DIR}/$1.yaml" || true
}

# The release notes, which helm template does not print. A client-side dry run needs no cluster.
notes() {
  helm install "${HELM_RELEASE}" "${HELM_CHART_PATH}" --namespace "${ISTIO_NAMESPACE}" --dry-run=client "$@" \
    | sed -n '/^NOTES:/,$p'
}

expect() {
  local what="$1" got="$2" want="$3"
  [[ "${got}" == "${want}" ]] || fail "${what}: expected '${want}', got '${got}'"
}

# --- 1. openshift: trusted ztunnel namespace and the Pod Security Standards hook ---
render openshift --set global.platform=openshift
expect "openshift trusted ztunnel" "$(trusted_ztunnel openshift)" "${ISTIO_NAMESPACE}/ztunnel"
expect "openshift patch-pss resources" "$(patch_pss_count openshift)" "0"

render openshift-explicit-ns --set global.platform=openshift --set istiod.trustedZtunnelNamespace=kube-system
expect "explicit trusted ztunnel namespace" "$(trusted_ztunnel openshift-explicit-ns)" "kube-system/ztunnel"

render openshift-pss-on --set global.platform=openshift --set ENABLE_PRIVILEGED_PSS=true
expect "openshift patch-pss resources with ENABLE_PRIVILEGED_PSS=true" "$(patch_pss_count openshift-pss-on)" "0"

# The upstream charts also read the platform from their own values.
render openshift-subcharts --set istiod.platform=openshift --set cni.platform=openshift --set ztunnel.platform=openshift
expect "openshift trusted ztunnel set on the subcharts" "$(trusted_ztunnel openshift-subcharts)" "${ISTIO_NAMESPACE}/ztunnel"
expect "openshift patch-pss resources set on the subcharts" "$(patch_pss_count openshift-subcharts)" "0"

render openshift-cni-only --set cni.platform=openshift
expect "openshift patch-pss resources set on cni only" "$(patch_pss_count openshift-cni-only)" "0"
notes --set cni.platform=openshift | grep -q 'On OpenShift the istio-cni and ztunnel pods are admitted' \
  || fail "release notes with the platform set on cni only do not describe OpenShift"
notes | grep -q 'A pre-install/pre-upgrade hook labelled namespace' \
  || fail "release notes without a platform do not describe the hook"

# --- 2. gke: CNI binary directory ---
render gke --set global.platform=gke
expect "gke CNI binary directory" "$(cni_bin_dir gke)" "/home/kubernetes/bin"

# The cni chart's own platform comes first, as in upstream.
render gke-cni-only --set global.platform=openshift --set cni.platform=gke
expect "gke CNI binary directory set on cni only" "$(cni_bin_dir gke-cni-only)" "/home/kubernetes/bin"

# --- 3. No platform: the defaults stay as they were ---
render none
expect "default trusted ztunnel" "$(trusted_ztunnel none)" "${ISTIO_NAMESPACE}/ztunnel"
expect "default CNI binary directory" "$(cni_bin_dir none)" "/opt/cni/bin"
[[ "$(patch_pss_count none)" -gt 0 ]] || fail "patch-pss resources missing without a platform"
