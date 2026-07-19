#!/usr/bin/env bash
# Smoke tests for the root command, exit codes, help/version, and global
# error handling.

source "$(dirname "${BASH_SOURCE[0]}")/lib/framework.sh"

# ─── Root command ────────────────────────────────────────────────────────

test_root_no_args_shows_help() {
    run_fluxview
    # Cobra with no subcommand args prints help to stdout (exit 0 in this build).
    # Either way, the binary must not crash.
    if [[ "$LAST_EXIT" == "0" || "$LAST_EXIT" == "1" ]]; then
        pass "root with no args returns 0 or 1 (got $LAST_EXIT)"
    else
        fail "root with no args returns 0 or 1" "got exit=$LAST_EXIT"
    fi
    assert_stdout_contains "fluxview" "help mentions fluxview"
    assert_stdout_contains "build" "help lists build subcommand"
    assert_stdout_contains "diff" "help lists diff subcommand"
    assert_stdout_contains "validate" "help lists validate subcommand"
}

test_root_help() {
    run_fluxview --help
    assert_exit_code 0 "fluxview --help succeeds"
    assert_stdout_contains "Usage:" "help shows usage"
    assert_stdout_contains "build" "help lists build"
    assert_stdout_contains "diff" "help lists diff"
    assert_stdout_contains "validate" "help lists validate"
}

test_root_help_short() {
    run_fluxview -h
    assert_exit_code 0 "fluxview -h succeeds"
    assert_stdout_contains "Usage:" "-h shows usage"
}

test_root_version() {
    run_fluxview --version
    assert_exit_code 0 "fluxview --version succeeds"
    assert_stdout_contains "fluxview version" "version output present"
}

test_root_version_short() {
    run_fluxview -v
    # Cobra accepts -v as version shorthand when Version is set.
    if [[ "$LAST_EXIT" == "0" ]]; then
        pass "fluxview -v shows version"
        assert_stdout_contains "fluxview version" "version output present"
    else
        # Some builds may not bind -v; treat as a soft failure.
        fail "fluxview -v shows version" "got exit=$LAST_EXIT"
    fi
}

# ─── Exit codes (contract from README) ───────────────────────────────────

test_exit_code_success_build() {
    run_fluxview build ks --path "$CLUSTER_PATH"
    assert_exit_code 0 "build success = exit 0"
}

test_exit_code_diff_found() {
    run_fluxview diff ks --path "$CLUSTER_PATH" --branch-orig "$DIFF_BASE_REV" --color never
    assert_exit_code 1 "diff with differences = exit 1"
}

test_exit_code_error_bad_path() {
    run_fluxview build ks --path "/tmp/nonexistent-xyz-$$"
    assert_exit_code 2 "operational error = exit 2"
}

test_exit_code_validation_failed() {
    run_fluxview validate --path "$INVALID_CLUSTER_PATH"
    assert_exit_code 3 "validation failure = exit 3"
}

# ─── Unknown command / flag ──────────────────────────────────────────────

test_root_unknown_subcommand() {
    run_fluxview frobnicate
    # Cobra rejects unknown subcommands.
    if [[ "$LAST_EXIT" == "1" || "$LAST_EXIT" == "2" ]]; then
        pass "unknown subcommand rejected (exit $LAST_EXIT)"
    else
        fail "unknown subcommand rejected" "got exit=$LAST_EXIT"
    fi
}

test_unknown_flag() {
    run_fluxview build ks --path "$CLUSTER_PATH" --no-such-flag
    if [[ "$LAST_EXIT" -ge 1 ]]; then
        pass "unknown flag rejected (exit $LAST_EXIT)"
    else
        fail "unknown flag rejected" "got exit=$LAST_EXIT"
    fi
    assert_contains "unknown flag" "error mentions unknown flag"
}

# ─── Global flags ────────────────────────────────────────────────────────

test_build_help_lists_all_subcommands() {
    run_fluxview build --help
    assert_exit_code 0 "build --help succeeds"
    assert_stdout_contains "ks" "build help lists ks"
    assert_stdout_contains "hr" "build help lists hr"
}

test_diff_help_lists_all_subcommands() {
    run_fluxview diff --help
    assert_exit_code 0 "diff --help succeeds"
    assert_stdout_contains "ks" "diff help lists ks"
    assert_stdout_contains "hr" "diff help lists hr"
}

# ─── Registration ────────────────────────────────────────────────────────

test_case "root_no_args_shows_help"       test_root_no_args_shows_help
test_case "root_help"                     test_root_help
test_case "root_help_short"               test_root_help_short
test_case "root_version"                  test_root_version
test_case "root_version_short"            test_root_version_short
test_case "exit_code_success_build"       test_exit_code_success_build
test_case "exit_code_diff_found"          test_exit_code_diff_found
test_case "exit_code_error_bad_path"      test_exit_code_error_bad_path
test_case "exit_code_validation_failed"   test_exit_code_validation_failed
test_case "root_unknown_subcommand"       test_root_unknown_subcommand
test_case "unknown_flag"                  test_unknown_flag
test_case "build_help_lists_subcommands" test_build_help_lists_all_subcommands
test_case "diff_help_lists_subcommands"   test_diff_help_lists_all_subcommands
