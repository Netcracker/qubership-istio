#!/usr/bin/env bash
set -euo pipefail

# Verifies the values this distribution picks for a platform, from rendered manifests only:
#   - openshift: istiod trusts ztunnel in the release namespace instead of the profile's
#     kube-system, and the Pod Security Standards hook is skipped even when enabled;
#   - gke: the CNI plugin goes to /home/kubernetes/bin without a -gke cluster version;
#   - an explicit value still wins over both defaults, and no platform keeps the old behavior.

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

# --- 2. gke: CNI binary directory ---
render gke --set global.platform=gke
expect "gke CNI binary directory" "$(cni_bin_dir gke)" "/home/kubernetes/bin"

render gke-explicit --set global.platform=gke --set cni.cniBinDir=/opt/custom/bin
expect "explicit CNI binary directory" "$(cni_bin_dir gke-explicit)" "/opt/custom/bin"

render gke-explicit-nested --set global.platform=gke --set cni.cni.cniBinDir=/opt/nested/bin
expect "explicit nested CNI binary directory" "$(cni_bin_dir gke-explicit-nested)" "/opt/nested/bin"

# --- 3. No platform: the defaults stay as they were ---
render none
expect "default trusted ztunnel" "$(trusted_ztunnel none)" "${ISTIO_NAMESPACE}/ztunnel"
expect "default CNI binary directory" "$(cni_bin_dir none)" "/opt/cni/bin"
[[ "$(patch_pss_count none)" -gt 0 ]] || fail "patch-pss resources missing without a platform"
