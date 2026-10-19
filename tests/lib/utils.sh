#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Common helpers for the test scripts. Sourced — not executed.
#
# Logging and failure. test-suite.sh exports RED_COLOR, GREEN_COLOR and
# RESET_COLOR; run outside it, the output is plain.
#
#   log  <message>   progress, with a timestamp, on stderr
#   ok   <message>   a passed check, on stdout
#   fail <message>   an error on stderr, then exit 1. Inside $(...) it ends the
#                    subshell only; under `set -e` the failed assignment then
#                    ends the script.
#
# Kubernetes objects from the chart in tests/lib/fixtures, rendered with
# helm template and applied with kubectl, never installed as a release: a
# release would keep a snapshot of thousands of Services and diff it on every
# step. See tests/lib/fixtures/values.yaml for the blocks and their values.
#
#   fixtures_render --set-string gateway.name=gw --set-string gateway.namespace=ns
#   fixtures_apply  --set-string gateway.name=gw --set-string gateway.namespace=ns
#   fixtures_create ...   (kubectl create: faster for thousands of new objects)
# ---------------------------------------------------------------------------

[ -n "${_TESTS_LIB_UTILS:-}" ] && return 0
_TESTS_LIB_UTILS=1

# ---------------------------------------------------------------------------
# Logging and failure
# ---------------------------------------------------------------------------

log() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2
}

ok() {
  printf '%bOK: %s%b\n' "${GREEN_COLOR:-}" "$*" "${RESET_COLOR:-}"
}

fail() {
  printf '%bError: %s%b\n' "${RED_COLOR:-}" "$*" "${RESET_COLOR:-}" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

FIXTURES_CHART="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures"

# fixtures_render <helm arguments...>: the objects as YAML on stdout.
fixtures_render() {
  helm template fixtures "${FIXTURES_CHART}" "$@" || fail "rendering ${FIXTURES_CHART} failed: $*"
}

# fixtures_apply <helm arguments...>
fixtures_apply() {
  local manifest
  manifest=$(fixtures_render "$@") || return 1
  [ -n "${manifest}" ] || fail "nothing rendered from ${FIXTURES_CHART}: $*"
  kubectl apply -f - >/dev/null <<<"${manifest}"
}

# fixtures_create <helm arguments...>: kubectl create, which is faster than
# apply for thousands of new objects and fails if one already exists.
fixtures_create() {
  local manifest
  manifest=$(fixtures_render "$@") || return 1
  [ -n "${manifest}" ] || fail "nothing rendered from ${FIXTURES_CHART}: $*"
  kubectl create -f - >/dev/null <<<"${manifest}"
}
