#!/usr/bin/env bash
# Smoke tests for `fluxview diff hr`.
#
# Verifies Helm chart inflation diff: detects value changes across revisions
# (exit 1), no-changes path (exit 0), name filter, and graceful handling of
# unsupported HelmReleases in both states.

source "$(dirname "${BASH_SOURCE[0]}")/lib/framework.sh"

# Commit 2 changed: backend replicaCount 2 -> 5, nginx tag 1.25 -> 1.27;
# podinfo valuesFrom ConfigMap (color/message) was modified.

# ─── Changes detected ────────────────────────────────────────────────────

test_diff_hr_detects_changes() {
    run_fluxview diff hr --path "$CLUSTER_PATH" --branch-orig "$DIFF_BASE_REV" --color never
    assert_exit_code 1 "diff hr detects changes"
    assert_stdout_contains "Deployment: backend" "backend diff appears"
    assert_stdout_contains "Deployment: podinfo" "podinfo diff appears"
}

test_diff_hr_backend_image_change() {
    run_fluxview diff hr backend --path "$CLUSTER_PATH" --branch-orig "$DIFF_BASE_REV" --color never
    assert_exit_code 1 "diff hr backend detects changes"
    assert_stdout_contains "image: nginx:1.27" "new image tag appears in diff"
    assert_stdout_contains "image: nginx:1.25" "old image tag appears in diff"
}

test_diff_hr_backend_replicas_change() {
    run_fluxview diff hr backend --path "$CLUSTER_PATH" --branch-orig "$DIFF_BASE_REV" --color never
    assert_exit_code 1 "diff hr backend detects replicas change"
    assert_stdout_contains "replicas: 5" "new replicas appears"
    assert_stdout_contains "replicas: 2" "old replicas appears"
}

test_diff_hr_podinfo_values_change() {
    run_fluxview diff hr podinfo --path "$CLUSTER_PATH" --branch-orig "$DIFF_BASE_REV" --color never
    assert_exit_code 1 "diff hr podinfo detects ConfigMap values change"
    # valuesFrom values propagate into podinfo env vars (PODINFO_UI_COLOR etc.).
    assert_stdout_contains "PODINFO_UI_COLOR" "podinfo env var appears in diff"
}

# ─── No changes ──────────────────────────────────────────────────────────

test_diff_hr_no_changes_exit_zero() {
    run_fluxview diff hr --path "$CLUSTER_PATH" --branch-orig HEAD --color never
    assert_exit_code 0 "diff hr with no changes exits 0"
    assert_stderr_contains "No differences found." "stderr reports no differences"
}

# ─── Filters ─────────────────────────────────────────────────────────────

test_diff_hr_namespace_filter() {
    # Note: namespace filter requires the chart templates to set metadata.namespace
    # (e.g. via {{ .Release.Namespace }}). The podinfo chart does this; the local
    # backend chart does not, so backend resources are filtered out — known gap.
    run_fluxview diff hr --path "$CLUSTER_PATH" --branch-orig "$DIFF_BASE_REV" --namespace podinfo --color never
    assert_exit_code 1 "diff hr --namespace podinfo detects changes"
    assert_stdout_contains "Deployment: podinfo" "podinfo present"
    assert_not_contains "Deployment: backend" "backend excluded"
}

test_diff_hr_namespace_filter_known_gap() {
    # KNOWN GAP: diff hr --namespace <ns> uses resource-level filtering, which
    # requires metadata.namespace in rendered output. Helm charts that don't
    # template {{ .Release.Namespace }} (like our local backend chart) produce
    # resources without an explicit namespace, so the filter drops them.
    # This documents the gap — flux-local-style behavior would set the namespace
    # during inflation. Logged as a non-failing observation.
    run_fluxview diff hr --path "$CLUSTER_PATH" --branch-orig "$DIFF_BASE_REV" --namespace backend --color never
    if [[ "$LAST_EXIT" == "0" ]] && printf '%s' "$LAST_STDERR" | grep -q "No resources found in namespace"; then
        pass "diff hr --namespace backend hits known resource-level filter gap"
    else
        fail "diff hr namespace gap" "unexpected behavior: exit=$LAST_EXIT, stderr=$(printf '%s' "$LAST_STDERR" | head -1)"
    fi
}

test_diff_hr_color_never_prefix() {
    run_fluxview diff hr backend --path "$CLUSTER_PATH" --branch-orig "$DIFF_BASE_REV" --color never
    assert_exit_code 1 "diff hr color never works"
    assert_stdout_contains "+    replicas: 5" "added line has + prefix"
    assert_stdout_contains "-    replicas: 2" "removed line has - prefix"
}

# ─── Unsupported HRs in both states ──────────────────────────────────────

test_diff_hr_unsupported_skipped_in_both_states() {
    # Bucket and HelmChart chartRef HRs must be skipped in BOTH current and
    # comparison states — they should not appear in the diff at all.
    run_fluxview diff hr --path "$CLUSTER_PATH" --branch-orig "$DIFF_BASE_REV" --color never
    assert_exit_code 1 "diff hr still detects real changes"
    assert_stderr_contains "Bucket-sourced chart" "Bucket warning emitted (at least once)"
    assert_stderr_contains "has no chart name" "HelmChart chartRef warning emitted"
    assert_not_contains "Deployment: bucket-app" "Bucket HR not inflated"
    assert_not_contains "Deployment: helmchart-hr" "HelmChart HR not inflated"
}

# ─── Error paths ─────────────────────────────────────────────────────────

test_diff_hr_unknown_name() {
    run_fluxview diff hr nonexistent-hr --path "$CLUSTER_PATH" --branch-orig "$DIFF_BASE_REV"
    # When name filter matches no HR in the current state, buildHRInflation
    # returns an error (same as build hr unknown name).
    assert_exit_code 2 "diff hr unknown name fails"
    assert_stderr_contains "not found" "error reports not found"
}

test_diff_hr_help() {
    run_fluxview diff hr --help
    assert_exit_code 0 "diff hr --help succeeds"
    assert_stdout_contains "helmrelease" "help mentions helmrelease alias"
}

# ─── Registration ────────────────────────────────────────────────────────

test_case "diff_hr_detects_changes"                test_diff_hr_detects_changes
test_case "diff_hr_backend_image_change"           test_diff_hr_backend_image_change
test_case "diff_hr_backend_replicas_change"        test_diff_hr_backend_replicas_change
test_case "diff_hr_podinfo_values_change"          test_diff_hr_podinfo_values_change
test_case "diff_hr_no_changes_exit_zero"           test_diff_hr_no_changes_exit_zero
test_case "diff_hr_namespace_filter"               test_diff_hr_namespace_filter
test_case "diff_hr_namespace_filter_known_gap"     test_diff_hr_namespace_filter_known_gap
test_case "diff_hr_color_never_prefix"             test_diff_hr_color_never_prefix
test_case "diff_hr_unsupported_skipped_both"       test_diff_hr_unsupported_skipped_in_both_states
test_case "diff_hr_unknown_name"                   test_diff_hr_unknown_name
test_case "diff_hr_help"                           test_diff_hr_help
