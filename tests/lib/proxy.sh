#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Reading an Istio proxy (gateway or waypoint), and changing an istiod
# environment variable through the chart. Sourced — not executed.
#
# The caller sets ISTIO_NAMESPACE; istiod_set_env also needs HELM_RELEASE and
# HELM_CHART_PATH. Checks (proxy_has_cluster) and reads (proxy_stat) return
# non-zero for the caller to handle; waits end the script through fail() when
# they time out. All of them work with and without `set -o pipefail`.
# ---------------------------------------------------------------------------

[ -n "${_TESTS_LIB_PROXY:-}" ] && return 0
_TESTS_LIB_PROXY=1

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/utils.sh"

# proxy_pod <namespace> <label selector>
# The one Ready pod of a selector, once the pods of a previous rollout are gone.
proxy_pod() {
  local ns="$1" sel="$2" pods
  for _ in $(seq 1 90); do
    pods=$(kubectl get pod -n "${ns}" -l "${sel}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
    if [ "$(printf '%s\n' "${pods}" | grep -c .)" -eq 1 ] &&
       kubectl wait -n "${ns}" --for=condition=Ready "pod/${pods}" --timeout=5s >/dev/null 2>&1; then
      echo "${pods}"
      return 0
    fi
    sleep 5
  done
  fail "no single Ready pod for ${sel} in ${ns}"
}

# proxy_admin <namespace> <pod> <admin path>
proxy_admin() {
  local err rc=0
  err=$(mktemp)
  kubectl exec -n "$1" "$2" -c istio-proxy -- pilot-agent request GET "$3" 2>"${err}" || rc=$?
  grep -v 'GOMEMLIMIT is already set' "${err}" >&2 || true
  rm -f "${err}"
  return "${rc}"
}

# proxy_stat <namespace> <pod> <stat name>: the value of one Envoy stat.
proxy_stat() {
  local out
  out=$(proxy_admin "$1" "$2" "stats?filter=^$3\$") || return 1
  awk '{print $2}' <<<"${out}"
}

# proxy_memory <namespace> <pod>: "<working set> <peak>" of the istio-proxy
# container in MiB. The images are distroless, so nothing is read inside the
# container. The working set comes from the kubelet summary API, the value
# the kubelet evicts and reports by. The peak is memory.peak of the container
# cgroup (cgroup v2, kernel 5.19+), read through the node container, so only
# on kind; elsewhere it is empty. Either is empty when it cannot be read.
proxy_memory() {
  local ns="$1" pod="$2" node cid ws="" peak=""
  node=$(kubectl get pod -n "${ns}" "${pod}" -o jsonpath='{.spec.nodeName}')
  ws=$({ kubectl get --raw "/api/v1/nodes/${node}/proxy/stats/summary" 2>/dev/null || true; } |
    python3 -c '
import json, sys
ns, pod = sys.argv[1], sys.argv[2]
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit()
for p in data.get("pods", []):
    if p["podRef"]["namespace"] == ns and p["podRef"]["name"] == pod:
        for c in p.get("containers", []):
            if c["name"] == "istio-proxy" and "workingSetBytes" in c.get("memory", {}):
                print("%.1f" % (c["memory"]["workingSetBytes"] / 1048576))
' "${ns}" "${pod}")
  cid=$(kubectl get pod -n "${ns}" "${pod}" \
    -o jsonpath='{.status.containerStatuses[?(@.name=="istio-proxy")].containerID}')
  cid="${cid#*://}"
  if [ -n "${cid}" ] && command -v docker >/dev/null 2>&1 &&
     docker inspect "${node}" >/dev/null 2>&1; then
    peak=$(docker exec "${node}" sh -c \
      "d=\$(find /sys/fs/cgroup -type d -name '*${cid}*' 2>/dev/null | head -1); [ -n \"\$d\" ] && cat \"\$d/memory.peak\"" \
      2>/dev/null | awk 'NF { printf "%.1f", $1 / 1048576 }' || true)
  fi
  echo "${ws:--} ${peak:--}"
}

# proxy_has_cluster <namespace> <pod> <cluster>
# Lines of GET clusters start with "<cluster name>::".
proxy_has_cluster() {
  local out
  out=$(proxy_admin "$1" "$2" clusters 2>/dev/null) || return 1
  grep -qF "$3::" <<<"${out}"
}

# proxy_outbound_clusters <namespace> <pod>: names of the outbound clusters.
proxy_outbound_clusters() {
  local out
  out=$(proxy_admin "$1" "$2" clusters 2>/dev/null) || return 1
  grep -F 'outbound|' <<<"${out}" | sed 's/::.*//' | sort -u
}

# proxy_wait_cluster <namespace> <pod> present|absent <cluster>
# istiod pushes asynchronously; waits up to two minutes.
proxy_wait_cluster() {
  local ns="$1" pod="$2" want="$3" cluster="$4"
  for i in $(seq 1 24); do
    if proxy_has_cluster "${ns}" "${pod}" "${cluster}"; then
      [ "${want}" = present ] && return 0
    else
      [ "${want}" = absent ] && return 0
    fi
    log "waiting for ${cluster} to be ${want} (${i}/24)"
    sleep 5
  done
  log "outbound clusters of ${pod}:"
  proxy_outbound_clusters "${ns}" "${pod}" >&2 || true
  fail "cluster ${cluster}: expected ${want}"
}

# proxy_wait_clusters_settled <namespace> <pod> <minimum>
# Waits until the proxy holds at least <minimum> Envoy clusters and the count
# has not changed over three reads, then prints the count.
proxy_wait_clusters_settled() {
  local ns="$1" pod="$2" min="$3" prev=-1 same=0 cur=0
  for _ in $(seq 1 120); do
    cur=$(proxy_stat "${ns}" "${pod}" cluster_manager.active_clusters || echo 0)
    if [ "${cur:-0}" -ge "${min}" ] && [ "${cur}" = "${prev}" ]; then
      same=$((same + 1))
      if [ "${same}" -ge 3 ]; then
        sleep 15
        echo "${cur}"
        return 0
      fi
    else
      same=0
    fi
    prev="${cur}"
    sleep 5
  done
  fail "clusters on ${pod} did not settle at >= ${min} (last ${cur})"
}

# proxy_wait_clusters_below <namespace> <pod> <maximum>
proxy_wait_clusters_below() {
  local ns="$1" pod="$2" max="$3" cur=0
  for _ in $(seq 1 60); do
    cur=$(proxy_stat "${ns}" "${pod}" cluster_manager.active_clusters || echo 0)
    [ "${cur:-0}" -lt "${max}" ] && return 0
    sleep 5
  done
  fail "clusters on ${pod} stayed at ${cur}, expected below ${max}"
}

# istiod_set_env <name> <value>
# Sets istiod.env.<name> on the release, which restarts istiod, and waits for it.
istiod_set_env() {
  log "istiod: ${1}=${2}"
  helm upgrade "${HELM_RELEASE}" "${HELM_CHART_PATH}" \
    --namespace "${ISTIO_NAMESPACE}" \
    --timeout 3m \
    --wait \
    --reuse-values \
    --set-string "istiod.env.$1=$2" >/dev/null
  kubectl rollout status deployment/istiod -n "${ISTIO_NAMESPACE}" --timeout=180s >/dev/null
}
