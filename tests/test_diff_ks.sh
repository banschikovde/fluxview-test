#!/usr/bin/env bash
# Smoke tests for `fluxview diff ks`.
#
# Verifies diff against the previous commit (HEAD~1, configurable via
# DIFF_BASE_REV): changes detected (exit 1), no changes (exit 0), name /
# namespace filters, --skip-crds, --strip-attrs, --unified, --color modes,
# and error paths.

source "$(dirname "${BASH_SOURCE[0]}")/lib/framework.sh"

# Diff tests need a git base revision with known differences. The repo has:
#   - podinfo ui.color/message changed in configmap-values.yaml
#   - infra backend replicas 1 -> 3
#   - backend HelmRelease replicaCount 2 -> 5, tag 1.25 -> 1.27

# ─── Changes detected (exit 1) ───────────────────────────────────────────

test_diff_ks_detects_changes() {
    run_fluxview diff ks --path "$CLUSTER_PATH" --branch-orig "$DIFF_BASE_REV" --color never
    assert_exit_code 1 "diff detects changes (exit 1)"
    assert_stdout_contains "ConfigMap: podinfo/podinfo-values" "diff includes podinfo-values"
    assert_stdout_contains "Deployment: infra/backend" "diff includes infra backend"
    assert_stdout_contains "HelmRelease: backend/backend" "diff includes backend HelmRelease"
}

test_diff_ks_no_changes_exit_zero() {
    # Comparing HEAD against itself yields no diff.
    run_fluxview diff ks --path "$CLUSTER_PATH" --branch-orig HEAD --color never
    assert_exit_code 0 "diff with no changes exits 0"
    assert_stderr_contains "No differences found." "stderr reports no differences"
}

test_diff_ks_unified_context_lines() {
    # --unified 0 hides all context lines; verify both + and - lines still appear.
    run_fluxview diff ks --path "$CLUSTER_PATH" --branch-orig "$DIFF_BASE_REV" --color never --unified 0
    assert_exit_code 1 "diff --unified 0 detects changes"
    assert_stdout_contains 'replicas: 1' "removed line present"
    assert_stdout_contains 'replicas: 3' "added line present"
}

test_diff_ks_unified_more_context() {
    # --unified 10 exposes more context — verify the diff is still correct.
    run_fluxview diff ks --path "$CLUSTER_PATH" --branch-orig "$DIFF_BASE_REV" --color never --unified 10
    assert_exit_code 1 "diff --unified 10 detects changes"
    # Context lines around replicas change should include selector/matchLabels.
    assert_stdout_contains "matchLabels:" "wider context shows matchLabels"
}

# ─── Color modes ─────────────────────────────────────────────────────────

test_diff_ks_color_never_uses_prefix() {
    run_fluxview diff ks --path "$CLUSTER_PATH" --branch-orig "$DIFF_BASE_REV" --color never
    assert_exit_code 1 "color never detects changes"
    # In pipe mode, +/- prefixes appear.
    assert_stdout_contains '+      color: "#6b21a8"' "added line has + prefix"
    assert_stdout_contains '-      color: "#114463"' "removed line has - prefix"
}

test_diff_ks_color_always_emits_ansi() {
    run_fluxview diff ks --path "$CLUSTER_PATH" --branch-orig "$DIFF_BASE_REV" --color always
    assert_exit_code 1 "color always detects changes"
    # ANSI escape codes appear in the output when color is forced.
    if printf '%s' "$LAST_STDOUT" | grep -q $'\033\['; then
        pass "ANSI color codes emitted"
    else
        fail "ANSI color codes emitted" "no \\033[ sequences in stdout"
    fi
}

# ─── Filters ─────────────────────────────────────────────────────────────

test_diff_ks_by_name_apps() {
    # Diff only the "apps" Kustomization. infra/backend change should be excluded
    # (infra KS is not "apps"), but podinfo-values (under apps KS) should appear.
    run_fluxview diff ks apps --path "$CLUSTER_PATH" --branch-orig "$DIFF_BASE_REV" --color never
    assert_exit_code 1 "diff ks apps detects changes"
    assert_stdout_contains "ConfigMap: podinfo/podinfo-values" "apps diff includes podinfo-values"
    assert_not_contains "Deployment: infra/backend" "infra change excluded by name filter"
}

test_diff_ks_namespace_filter() {
    run_fluxview diff ks --path "$CLUSTER_PATH" --branch-orig "$DIFF_BASE_REV" --namespace podinfo --color never
    assert_exit_code 1 "diff --namespace podinfo detects changes"
    assert_stdout_contains "ConfigMap: podinfo/podinfo-values" "podinfo CM present"
    assert_not_contains "Deployment: infra/backend" "infra excluded by ns filter"
}

test_diff_ks_skip_crds() {
    run_fluxview diff ks --path "$CLUSTER_PATH" --branch-orig "$DIFF_BASE_REV" --skip-crds --color never
    assert_exit_code 1 "diff --skip-crds detects changes"
    assert_not_contains "CustomResourceDefinition:" "no CRDs in diff output"
}

test_diff_ks_strip_attrs() {
    # Strip status from diff to suppress noisy churn.
    run_fluxview diff ks --path "$CLUSTER_PATH" --branch-orig "$DIFF_BASE_REV" --strip-attrs status --color never
    assert_exit_code 1 "diff --strip-attrs detects changes"
    assert_stdout_contains "ConfigMap: podinfo/podinfo-values" "diff still produced"
}

# ─── Auto-detected default branch ────────────────────────────────────────

test_diff_ks_auto_default_branch() {
    # No --branch-orig: fluxview auto-detects the default branch.
    # In this repo, default branch is main, which is HEAD (no diff vs itself).
    run_fluxview diff ks --path "$CLUSTER_PATH" --color never
    assert_exit_code 0 "auto-detected default branch diff exits 0 (main == HEAD)"
    assert_stderr_contains "default branch" "stderr mentions default branch detection"
}

# ─── Error paths ─────────────────────────────────────────────────────────

test_diff_ks_no_resource_type() {
    run_fluxview diff --path "$CLUSTER_PATH"
    # diff uses cobra.MinimumNArgs(1); error is cobra's standard message.
    assert_exit_code 2 "diff without resource type fails"
    assert_stderr_contains "requires at least 1 arg" "error explains required arg"
}

test_diff_ks_unsupported_type() {
    run_fluxview diff widgets --path "$CLUSTER_PATH"
    assert_exit_code 2 "unsupported diff resource type fails"
    assert_stderr_contains "unsupported resource type" "error mentions unsupported type"
}

test_diff_ks_nonexistent_path() {
    run_fluxview diff ks --path "/tmp/does-not-exist-$$"
    assert_exit_code 2 "diff with nonexistent path fails"
    assert_stderr_contains "does not exist" "error reports missing path"
}

test_diff_ks_invalid_base_revision() {
    run_fluxview diff ks --path "$CLUSTER_PATH" --branch-orig "not-a-real-revision-xyz"
    assert_exit_code 2 "diff with invalid base revision fails"
    assert_stderr_contains "resolving revision" "error reports revision resolution failure"
}

test_diff_ks_help() {
    run_fluxview diff ks --help
    assert_exit_code 0 "diff ks --help succeeds"
    assert_stdout_contains "--branch-orig" "help lists --branch-orig"
    assert_stdout_contains "--unified" "help lists --unified"
    assert_stdout_contains "--color" "help lists --color"
}

# ─── Registration ────────────────────────────────────────────────────────

test_case "diff_ks_detects_changes"           test_diff_ks_detects_changes
test_case "diff_ks_no_changes_exit_zero"      test_diff_ks_no_changes_exit_zero
test_case "diff_ks_unified_zero"              test_diff_ks_unified_context_lines
test_case "diff_ks_unified_more_context"      test_diff_ks_unified_more_context
test_case "diff_ks_color_never_prefix"        test_diff_ks_color_never_uses_prefix
test_case "diff_ks_color_always_ansi"         test_diff_ks_color_always_emits_ansi
test_case "diff_ks_by_name_apps"              test_diff_ks_by_name_apps
test_case "diff_ks_namespace_filter"          test_diff_ks_namespace_filter
test_case "diff_ks_skip_crds"                 test_diff_ks_skip_crds
test_case "diff_ks_strip_attrs"               test_diff_ks_strip_attrs
test_case "diff_ks_auto_default_branch"       test_diff_ks_auto_default_branch
test_case "diff_ks_no_resource_type"          test_diff_ks_no_resource_type
test_case "diff_ks_unsupported_type"          test_diff_ks_unsupported_type
test_case "diff_ks_nonexistent_path"          test_diff_ks_nonexistent_path
test_case "diff_ks_invalid_base_revision"     test_diff_ks_invalid_base_revision
test_case "diff_ks_help"                      test_diff_ks_help
