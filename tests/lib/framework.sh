#!/usr/bin/env bash
# Test framework for fluxview smoke tests.
#
# Provides assertion helpers and a small runner. Each test_<name>.sh sources
# this file and defines tests via the `test_case` function. The runner
# (`tests/run_all.sh`) discovers and executes test_*.sh files.
#
# Exit codes from the runner:
#   0  all tests passed
#   1  one or more tests failed (see $RESULTS_DIR for details)

set -o pipefail

# Guard against double-sourcing (runner sources this, then each test file
# sources it again). On the second source we just return — all definitions
# below are already in scope.
if [[ -n "${FLUXVIEW_FRAMEWORK_LOADED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
FLUXVIEW_FRAMEWORK_LOADED=1

# Resolve project root (one level up from tests/lib).
FLUXVIEW_TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly FLUXVIEW_TEST_ROOT

# Default paths used by scenarios.
readonly REPO_ROOT="$FLUXVIEW_TEST_ROOT"
readonly BIN_DIR="$REPO_ROOT/bin"
readonly FLUXVIEW_BIN="${FLUXVIEW_BIN:-$BIN_DIR/fluxview}"
readonly CLUSTER_PATH="$REPO_ROOT/k8s/test/cluster"
readonly INVALID_CLUSTER_PATH="$REPO_ROOT/k8s/invalid/cluster"

# Git revision used as the comparison base for diff tests. Defaults to the
# `smoke-base` tag (the "Base smoke test data..." commit); falls back to
# HEAD~1 if the tag is missing.
default_diff_base() {
    if git -C "$FLUXVIEW_TEST_ROOT" rev-parse --verify --quiet smoke-base >/dev/null; then
        echo "smoke-base"
    else
        echo "HEAD~1"
    fi
}
readonly DIFF_BASE_REV="${DIFF_BASE_REV:-$(default_diff_base)}"

# ─── Output / state ──────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    COLOR_GREEN=$'\033[32m'
    COLOR_RED=$'\033[31m'
    COLOR_YELLOW=$'\033[33m'
    COLOR_DIM=$'\033[2m'
    COLOR_RESET=$'\033[0m'
else
    COLOR_GREEN=''
    COLOR_RED=''
    COLOR_YELLOW=''
    COLOR_DIM=''
    COLOR_RESET=''
fi

# Global counters (accumulate across all test files).
TESTS_TOTAL=0
TESTS_PASSED=0
TESTS_FAILED=0
CURRENT_TEST=''

# Each test file records results here.
RESULTS_DIR="${RESULTS_DIR:-$REPO_ROOT/tests/.results}"
mkdir -p "$RESULTS_DIR"

# Capture of the last command's stdout/stderr/exit for inspection in tests.
LAST_STDOUT=''
LAST_STDERR=''
LAST_EXIT=''

# ─── Helpers ─────────────────────────────────────────────────────────────

# run_fluxview <args...>
# Stores output, error and exit code in LAST_STDOUT/LAST_STDERR/LAST_EXIT.
run_fluxview() {
    local out err rc
    out=$(mktemp); err=$(mktemp)
    "$FLUXVIEW_BIN" "$@" >"$out" 2>"$err"; rc=$?
    LAST_STDOUT=$(<"$out"); LAST_STDERR=$(<"$err"); LAST_EXIT=$rc
    local safe_name=${CURRENT_TEST//[^A-Za-z0-9._-]/_}
    [[ -z "$safe_name" ]] && safe_name=unknown
    cat "$out" > "$RESULTS_DIR/${safe_name}.stdout"
    cat "$err" > "$RESULTS_DIR/${safe_name}.stderr"
    rm -f "$out" "$err"
}

# ─── Assertions ──────────────────────────────────────────────────────────

pass() {
    TESTS_TOTAL=$((TESTS_TOTAL+1))
    TESTS_PASSED=$((TESTS_PASSED+1))
    printf '  %s✓%s %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$1"
}

fail() {
    TESTS_TOTAL=$((TESTS_TOTAL+1))
    TESTS_FAILED=$((TESTS_FAILED+1))
    printf '  %s✗%s %s\n' "$COLOR_RED" "$COLOR_RESET" "$1" >&2
    if [[ -n "${2:-}" ]]; then
        printf '      %s%s%s\n' "$COLOR_DIM" "$2" "$COLOR_RESET" >&2
    fi
    echo "$CURRENT_TEST :: $1" >> "$RESULTS_DIR/_failures.txt"
}

assert_exit_code() {
    local expected=$1 desc=$2
    if [[ "$LAST_EXIT" == "$expected" ]]; then
        pass "$desc (exit=$LAST_EXIT)"
    else
        fail "$desc" "expected exit=$expected, got exit=$LAST_EXIT
      stderr: $(printf '%s' "$LAST_STDERR" | head -3 | tr '\n' ' ')"
    fi
}

assert_contains() {
    local needle=$1 desc=$2
    if printf '%s' "$LAST_STDOUT$LAST_STDERR" | grep -qF -- "$needle"; then
        pass "$desc"
    else
        fail "$desc" "expected output to contain: $needle"
    fi
}

assert_stdout_contains() {
    local needle=$1 desc=$2
    if printf '%s' "$LAST_STDOUT" | grep -qF -- "$needle"; then
        pass "$desc"
    else
        fail "$desc" "expected stdout to contain: $needle"
    fi
}

assert_stderr_contains() {
    local needle=$1 desc=$2
    if printf '%s' "$LAST_STDERR" | grep -qF -- "$needle"; then
        pass "$desc"
    else
        fail "$desc" "expected stderr to contain: $needle"
    fi
}

assert_not_contains() {
    local needle=$1 desc=$2
    if printf '%s' "$LAST_STDOUT$LAST_STDERR" | grep -qF -- "$needle"; then
        fail "$desc" "output should NOT contain: $needle"
    else
        pass "$desc"
    fi
}

assert_regex() {
    local regex=$1 desc=$2
    if printf '%s' "$LAST_STDOUT$LAST_STDERR" | grep -qE -- "$regex"; then
        pass "$desc"
    else
        fail "$desc" "expected output to match regex: $regex"
    fi
}

# ─── Test registration ───────────────────────────────────────────────────

# Internal registry of test cases for the current file.
declare -a TEST_CASES=()
declare -A TEST_FUNCS=()

test_case() {
    local name=$1 fn=$2
    TEST_CASES+=("$name")
    TEST_FUNCS[$name]=$fn
}

# run_test_file <file>
# Sources <file>, runs all its registered test cases. Counters accumulate
# globally — no per-file reset.
run_test_file() {
    local file=$1
    local fname
    fname=$(basename "$file")
    printf '\n%s[%s]%s\n' "$COLOR_YELLOW" "$fname" "$COLOR_RESET"

    # Reset registry (test_case calls populate it fresh per file).
    TEST_CASES=()
    TEST_FUNCS=()

    # shellcheck disable=SC1090
    source "$file"

    for name in "${TEST_CASES[@]}"; do
        CURRENT_TEST="$fname::$name"
        printf '%s→ %s%s\n' "$COLOR_DIM" "$name" "$COLOR_RESET"
        "${TEST_FUNCS[$name]}" || true
    done
}

require_binary() {
    if [[ ! -x "$FLUXVIEW_BIN" ]]; then
        cat >&2 <<EOF
fluxview binary not found at $FLUXVIEW_BIN

Build it first from the fluxview source:
  (cd ../flux-diff && go build -o ../fluxview-test/bin/fluxview ./cmd/fluxview/)

Or set FLUXVIEW_BIN to point at an existing binary.
EOF
        exit 2
    fi
}
