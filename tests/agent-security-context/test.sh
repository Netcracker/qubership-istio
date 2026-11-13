#!/usr/bin/env bash
set -euo pipefail

# Renders the chart and checks the securityContext that tweak/agent-security-context/ puts on
# install-cni and istio-proxy: the defaults, with and without node tuning, a key set in the
# values, the nested form, OpenShift, and a null value.

RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "${RENDER_DIR}"' EXIT

render() {
  local out="$1"
  shift
  helm template "${HELM_RELEASE}" "${HELM_CHART_PATH}" --namespace "${ISTIO_NAMESPACE}" "$@" > "${RENDER_DIR}/${out}.yaml"
}

# A yq expression on the main container of a DaemonSet: <render> <daemonset> <container> <expression>.
container() {
  yq -r "select(.kind == \"DaemonSet\" and .metadata.name == \"$2\")
    | .spec.template.spec.containers[] | select(.name == \"$3\") | $4" "${RENDER_DIR}/$1.yaml"
}

# The same on the pod spec: <render> <daemonset> <expression>.
pod_spec() {
  yq -r "select(.kind == \"DaemonSet\" and .metadata.name == \"$2\") | .spec.template.spec | $3" "${RENDER_DIR}/$1.yaml"
}

cni() { container "$1" istio-cni-node install-cni "$2"; }
proxy() { container "$1" ztunnel istio-proxy "$2"; }

expect() {
  local what="$1" got="$2" want="$3"
  [[ "${got}" == "${want}" ]] || fail "${what}: expected '${want}', got '${got}'"
}

# What the tweak puts on both containers, and what it must leave alone.
expect_hardened() {
  local r="$1"
  expect "${r}: install-cni allowPrivilegeEscalation" "$(cni "${r}" '.securityContext.allowPrivilegeEscalation')" "false"
  expect "${r}: install-cni readOnlyRootFilesystem" "$(cni "${r}" '.securityContext.readOnlyRootFilesystem')" "null"
  expect "${r}: install-cni seccompProfile" "$(cni "${r}" '.securityContext.seccompProfile.type')" "RuntimeDefault"
  expect "${r}: install-cni added capabilities" "$(cni "${r}" '.securityContext.capabilities.add | length')" "5"
  expect "${r}: install-cni runAsUser" "$(cni "${r}" '.securityContext.runAsUser')" "0"
  expect "${r}: istio-proxy allowPrivilegeEscalation" "$(proxy "${r}" '.securityContext.allowPrivilegeEscalation')" "false"
  expect "${r}: istio-proxy seccompProfile" "$(proxy "${r}" '.securityContext.seccompProfile.type')" "RuntimeDefault"
  expect "${r}: istio-proxy readOnlyRootFilesystem" "$(proxy "${r}" '.securityContext.readOnlyRootFilesystem')" "true"
  expect "${r}: istio-proxy added capabilities" "$(proxy "${r}" '.securityContext.capabilities.add | length')" "3"
  expect "${r}: istio-proxy runAsGroup" "$(proxy "${r}" '.securityContext.runAsGroup')" "1337"
}

# One name per line from yq, joined with commas. An expression that builds an array would
# print once for every document of the render that is not the DaemonSet, so none does.
init_names() {
  pod_spec "$1" "$2" '.initContainers[]?.name' | paste -sd, -
}

node_inotify_volumes() {
  pod_spec "$1" "$2" '.volumes[] | select(.name == "node-inotify") | .name' | wc -l | tr -d ' '
}

# --- 1. Defaults ---
render default
expect_hardened default
expect "default: node tuning in istio-cni-node" "$(init_names default istio-cni-node)" "node-inotify-tuning"
expect "default: node tuning in ztunnel" "$(init_names default ztunnel)" "node-inotify-tuning"

# --- 2. Node tuning off: the same values, and no init container or volume ---
render no-tuning --set global.nodeTuning.enabled=false
expect_hardened no-tuning
for ds in istio-cni-node ztunnel; do
  expect "no tuning: init containers of ${ds}" "$(init_names no-tuning "${ds}")" ""
  expect "no tuning: node-inotify volumes of ${ds}" "$(node_inotify_volumes no-tuning "${ds}")" "0"
done

# --- 3. A key set in the values wins: one set back to upstream, one added ---
render custom \
  --set ztunnel.containerSecurityContext.allowPrivilegeEscalation=true \
  --set cni.containerSecurityContext.readOnlyRootFilesystem=true
expect "custom: istio-proxy allowPrivilegeEscalation" "$(proxy custom '.securityContext.allowPrivilegeEscalation')" "true"
expect "custom: install-cni readOnlyRootFilesystem" "$(cni custom '.securityContext.readOnlyRootFilesystem')" "true"
expect "custom: install-cni allowPrivilegeEscalation stays" "$(cni custom '.securityContext.allowPrivilegeEscalation')" "false"

# --- 4. The nested form, which the upstream charts also read ---
render nested --set cni.cni.containerSecurityContext.readOnlyRootFilesystem=true
expect "nested: install-cni readOnlyRootFilesystem" "$(cni nested '.securityContext.readOnlyRootFilesystem')" "true"

# --- 5. openshift: the platform's SELinux type stays next to the new keys ---
render openshift --set global.platform=openshift
expect "openshift: install-cni seLinuxOptions" "$(cni openshift '.securityContext.seLinuxOptions.type')" "spc_t"
expect "openshift: istio-proxy seLinuxOptions" "$(proxy openshift '.securityContext.seLinuxOptions.type')" "spc_t"
expect "openshift: install-cni allowPrivilegeEscalation" "$(cni openshift '.securityContext.allowPrivilegeEscalation')" "false"
expect "openshift: istio-proxy allowPrivilegeEscalation" "$(proxy openshift '.securityContext.allowPrivilegeEscalation')" "false"

# --- 6. A null value: the containers are as upstream renders them ---
render null --set cni.containerSecurityContext=null --set ztunnel.containerSecurityContext=null
expect "null: istio-proxy allowPrivilegeEscalation" "$(proxy null '.securityContext.allowPrivilegeEscalation')" "true"
expect "null: install-cni allowPrivilegeEscalation" "$(cni null '.securityContext.allowPrivilegeEscalation')" "null"
