#!/usr/bin/env bash
# Smoke tests for `fluxview validate`.
#
# Verifies CRD-schema validation: happy path (exit 0), schema violation
# (exit 3), custom CRD YAML schemas, JSON Schema support, --schema-dir flag,
# namespace filter, and missing-schema skip behavior.

source "$(dirname "${BASH_SOURCE[0]}")/lib/framework.sh"

# Bundled CRD schemas live at $REPO_ROOT/crds/ (default location).
readonly SCHEMA_DIR="$REPO_ROOT/crds"

# ─── Happy path ──────────────────────────────────────────────────────────

test_validate_happy() {
    # The cluster path holds valid Flux/Kustomize/HelmRelease resources plus
    # a Widget that conforms to its CRD.
    run_fluxview validate --path "$CLUSTER_PATH"
    assert_exit_code 0 "validate happy path exits 0"
    assert_stderr_contains "All resources valid." "stderr reports all valid"
    assert_stderr_contains "Loaded" "stderr reports schema count"
}

test_validate_loads_schemas() {
    run_fluxview validate --path "$CLUSTER_PATH"
    assert_exit_code 0 "validate loads schemas"
    # Default schema dir is ./crds; expect at least 10 Flux schemas + Widget CRD.
    assert_regex "Loaded [0-9]+ CRD schemas" "stderr shows schema count"
}

test_validate_schema_dir_explicit() {
    run_fluxview validate --path "$CLUSTER_PATH" --schema-dir "$SCHEMA_DIR"
    assert_exit_code 0 "validate with explicit --schema-dir succeeds"
    assert_stderr_contains "from $SCHEMA_DIR" "stderr mentions schema dir"
}

test_validate_namespace_filter() {
    # Validate only resources in the podinfo namespace.
    run_fluxview validate --path "$CLUSTER_PATH" --namespace podinfo
    assert_exit_code 0 "validate --namespace podinfo succeeds"
    assert_stderr_contains "All resources valid." "all podinfo resources valid"
}

test_validate_namespace_no_match() {
    run_fluxview validate --path "$CLUSTER_PATH" --namespace nonexistent-ns
    assert_exit_code 0 "validate with no matching ns exits 0"
    assert_stderr_contains "No resources found in namespace" "stderr reports no resources"
}

# ─── Schema violations ───────────────────────────────────────────────────

test_validate_invalid_resources_exit_3() {
    # k8s/invalid/ holds a Widget with size=250 (max 100) and color=purple
    # (not in enum) — both violate the bundled CRD schema.
    run_fluxview validate --path "$INVALID_CLUSTER_PATH"
    assert_exit_code 3 "validate with invalid resources exits 3"
    assert_stderr_contains "Widget invalid/bad-widget" "stderr reports the bad Widget"
    assert_stderr_contains "spec.size" "stderr mentions size field"
    assert_stderr_contains "spec.color" "stderr mentions color field"
}

test_validate_invalid_lists_errors() {
    run_fluxview validate --path "$INVALID_CLUSTER_PATH"
    assert_exit_code 3 "validate exits 3 for invalid resources"
    assert_stderr_contains "Invalid value: 250" "stderr shows offending value"
    assert_stderr_contains "Unsupported value: \"purple\"" "stderr shows unsupported enum"
}

test_validate_invalid_only_bad_resource() {
    # Only bad-widget should fail; good-widget conforms. Verify both error
    # marker and that no false positives appear.
    run_fluxview validate --path "$INVALID_CLUSTER_PATH"
    assert_exit_code 3 "validate finds at least one failure"
    assert_stderr_contains "bad-widget" "bad-widget is flagged"
    assert_not_contains "good-widget" "good-widget is not flagged"
}

# ─── Missing schema behavior ─────────────────────────────────────────────

test_validate_missing_schema_skipped() {
    # Point validate at a directory with no schemas at all. Resources without
    # a matching schema are silently skipped — validate should succeed.
    local empty_schemas
    empty_schemas=$(mktemp -d)
    run_fluxview validate --path "$CLUSTER_PATH" --schema-dir "$empty_schemas"
    assert_exit_code 0 "validate with no schemas succeeds"
    assert_stderr_contains "Loaded 0 CRD schemas" "stderr reports 0 schemas"
    assert_stderr_contains "All resources valid." "all (zero-schema) resources valid"
    rm -rf "$empty_schemas"
}

test_validate_yaml_crd_schema_format() {
    # The crds/ directory contains both JSON schemas (.json) and a YAML CRD
    # (widgets-crd.yaml). Verify the YAML CRD is loaded and applied to Widgets.
    run_fluxview validate --path "$CLUSTER_PATH"
    assert_exit_code 0 "validate with mixed schema formats succeeds"
    # If Widget CRD wasn't loaded, the Widget would be silently skipped.
    # The bad-widget scenario above confirms Widget schema IS applied.
}

# ─── Error paths ─────────────────────────────────────────────────────────

test_validate_nonexistent_path() {
    run_fluxview validate --path "/tmp/does-not-exist-$$"
    assert_exit_code 2 "validate nonexistent path fails"
    assert_stderr_contains "does not exist" "error reports missing path"
}

test_validate_path_without_kustomizations() {
    local empty_dir
    empty_dir=$(mktemp -d)
    run_fluxview validate --path "$empty_dir"
    assert_exit_code 2 "path without Kustomizations fails"
    assert_stderr_contains "no Kustomization files found" "error mentions no Kustomizations"
    rm -rf "$empty_dir"
}

test_validate_help() {
    run_fluxview validate --help
    assert_exit_code 0 "validate --help succeeds"
    assert_stdout_contains "--schema-dir" "help lists --schema-dir"
}

# ─── Known issues / documented behaviors ─────────────────────────────────

# Regression test for previously-known issue: validate with a relative
# --path used to produce spurious "could not read ... Rel: can't make X
# relative to Y" warnings because validate.go passed the raw clusterPath
# (not absClusterPath) to the parser/build functions. Fixed by the
# 'Fix: validate emits spurious warnings with relative --path' commit.
test_validate_relative_path_no_warnings() {
    cd "$REPO_ROOT"
    run_fluxview validate --path k8s/test/cluster/
    assert_exit_code 0 "validate with relative path succeeds"
    assert_not_contains "Rel: can't make" "no Rel warnings with relative --path (regression)"
}

# ─── Registration ────────────────────────────────────────────────────────

test_case "validate_happy"                       test_validate_happy
test_case "validate_loads_schemas"               test_validate_loads_schemas
test_case "validate_schema_dir_explicit"         test_validate_schema_dir_explicit
test_case "validate_namespace_filter"            test_validate_namespace_filter
test_case "validate_namespace_no_match"          test_validate_namespace_no_match
test_case "validate_invalid_exit_3"              test_validate_invalid_resources_exit_3
test_case "validate_invalid_lists_errors"        test_validate_invalid_lists_errors
test_case "validate_invalid_only_bad_resource"   test_validate_invalid_only_bad_resource
test_case "validate_missing_schema_skipped"      test_validate_missing_schema_skipped
test_case "validate_yaml_crd_schema_format"      test_validate_yaml_crd_schema_format
test_case "validate_nonexistent_path"            test_validate_nonexistent_path
test_case "validate_path_without_kustomizations" test_validate_path_without_kustomizations
test_case "validate_help"                        test_validate_help
test_case "validate_relative_path_no_warnings" test_validate_relative_path_no_warnings
