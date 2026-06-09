#!/bin/bash
set -e

# mandatory: path to the helm chart under test
HELM_CHART_PATH=${1:?Missed mandatory parameter: helm chart path}
export HELM_CHART_PATH

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export RED_COLOR='\033[31m'
export GREEN_COLOR='\033[32m'
export RESET_COLOR='\033[0m'

export ISTIO_NAMESPACE="${ISTIO_NAMESPACE:-istio-system}"
export HELM_RELEASE="${HELM_RELEASE:-qubership-istio}"

fail() {
  echo -e "${RED_COLOR}Test error: $1${RESET_COLOR}" >&2
  false
}
export -f fail

run_test() {
    local test_script="$SUITE_DIR/$1/test.sh"

    SCRIPT_DIR="$SUITE_DIR/$1"
    export SCRIPT_DIR

    echo -e "${GREEN_COLOR}Run tests: $1${RESET_COLOR}"
    if "$test_script"; then
        echo -e "${GREEN_COLOR}Tests passed: $1${RESET_COLOR}"
    else
        echo -e "${RED_COLOR}Tests failed: $1${RESET_COLOR}"
        exit 1
    fi
}

# optional: glob pattern to filter test folders (default: all)
TEST_FILTER=${2:-*}
find "$SUITE_DIR" -maxdepth 1 -mindepth 1 -name "$TEST_FILTER" -type d -printf "%f\n" | sort | while read -r test_name; do
  # Skip directories that are not tests (e.g. lib/ shared helpers).
  [ -f "$SUITE_DIR/$test_name/test.sh" ] || continue
  run_test "$test_name"
done

echo -e "${GREEN_COLOR}All tests passed${RESET_COLOR}"
