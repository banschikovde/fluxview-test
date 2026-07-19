#!/usr/bin/env bash
# Main runner for fluxview smoke tests.
#
# Usage:
#   tests/run_all.sh                  # run all tests
#   tests/run_all.sh tests/test_build_ks.sh   # run a specific file
#
# Environment:
#   FLUXVIEW_BIN   path to fluxview binary (default: bin/fluxview)
#   DIFF_BASE_REV  git revision to diff against (default: HEAD~1)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/framework.sh
source "$SCRIPT_DIR/lib/framework.sh"

require_binary

# Clean previous results.
rm -f "$RESULTS_DIR/_failures.txt"
rm -f "$RESULTS_DIR"/*.stdout "$RESULTS_DIR"/*.stderr "$RESULTS_DIR"/*.combined 2>/dev/null || true

# Discover test files: explicit args, or all tests/test_*.sh.
test_files=()
if [[ $# -gt 0 ]]; then
    for arg in "$@"; do
        test_files+=("$(cd "$(dirname "$arg")" && pwd)/$(basename "$arg")")
    done
else
    while IFS= read -r f; do
        test_files+=("$f")
    done < <(find "$SCRIPT_DIR" -maxdepth 1 -type f -name 'test_*.sh' | sort)
fi

if [[ ${#test_files[@]} -eq 0 ]]; then
    echo "No test files found in $SCRIPT_DIR" >&2
    exit 2
fi

printf '%sfluxview smoke tests%s\n' "$COLOR_YELLOW" "$COLOR_RESET"
printf '  binary:    %s\n' "$FLUXVIEW_BIN"
$FLUXVIEW_BIN --version | sed 's/^/  version:  /'
printf '  revision:  %s\n' "$DIFF_BASE_REV"
printf '  repo root: %s\n' "$REPO_ROOT"
printf '  tests:     %d file(s)\n' "${#test_files[@]}"

START_EPOCH=$(date +%s)

for tf in "${test_files[@]}"; do
    run_test_file "$tf"
done

END_EPOCH=$(date +%s)
DURATION=$((END_EPOCH-START_EPOCH))

# Summary.
printf '\n%s────────────────────────────────────────%s\n' "$COLOR_YELLOW" "$COLOR_RESET"
printf 'Total: %d  Passed: %s%d%s  Failed: %s%d%s  Time: %ds\n' \
    "$TESTS_TOTAL" \
    "$COLOR_GREEN" "$TESTS_PASSED" "$COLOR_RESET" \
    "$COLOR_RED" "$TESTS_FAILED" "$COLOR_RESET" \
    "$DURATION"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
    printf '\n%sFailures:%s\n' "$COLOR_RED" "$COLOR_RESET"
    if [[ -f "$RESULTS_DIR/_failures.txt" ]]; then
        sed 's/^/  /' "$RESULTS_DIR/_failures.txt"
    fi
    exit 1
fi

exit 0
