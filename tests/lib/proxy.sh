#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Reading an Istio proxy (gateway or waypoint) and changing an istiod
# environment variable through the chart.
# Sourced — not executed.
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

# proxy_cluster_names <namespace> <pod>: the names of the Envoy clusters, one
# per line. GET clusters prints dozens of lines per cluster, all starting with
# "<cluster name>::"; only the names are kept, so `set -x` does not echo the
# whole dump.
proxy_cluster_names() {
  proxy_admin "$1" "$2" clusters 2>/dev/null | sed -n 's/::observability_name::.*//p'
}

# proxy_has_cluster <namespace> <pod> <cluster>
proxy_has_cluster() {
  local names
  names=$(proxy_cluster_names "$1" "$2") || return 1
  grep -qxF "$3" <<<"${names}"
}

# proxy_outbound_clusters <namespace> <pod>: names of the outbound clusters.
proxy_outbound_clusters() {
  proxy_cluster_names "$1" "$2" | grep -F 'outbound|' | sort -u
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
