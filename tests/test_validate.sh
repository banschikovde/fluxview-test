#!/usr/bin/env bash
# Smoke tests for `fluxview validate`.
#
# Verifies the kubeconform-based validation: native Kubernetes resources
# against the default registry (downloaded + cached), CRD schemas from
# --schema-dir (JSON + YAML CRD converted on the fly), missing-schema
# skip behavior, --kubernetes-version, and the schema cache.

source "$(dirname "${BASH_SOURCE[0]}")/lib/framework.sh"

# Bundled validation schemas live at $REPO_ROOT/schemas/ (default location).
readonly SCHEMA_DIR="$REPO_ROOT/schemas"

# ─── Happy path ──────────────────────────────────────────────────────────

test_validate_happy() {
    # The cluster path holds valid Flux/Kustomize/HelmRelease resources, a
    # Widget that conforms to its CRD, and native k8s resources validated
    # against the default registry.
    run_fluxview validate --path "$CLUSTER_PATH"
    assert_exit_code 0 "validate happy path exits 0"
    assert_stderr_contains "All resources valid." "stderr reports all valid"
}

test_validate_announces_sources_before_build() {
    # The planned schema sources are printed before the (possibly slow)
    # build: the default schemas/ dir plus the Kubernetes registry.
    run_fluxview validate --path "$CLUSTER_PATH"
    assert_exit_code 0 "validate succeeds"
    assert_stderr_contains "Validating against schemas, Kubernetes schemas (Kubernetes " \
        "stderr announces schema sources"
    # The announcement must precede the build progress lines.
    if [[ "$(printf '%s\n' "$LAST_STDERR" | grep -n 'Building ' | head -1 | cut -d: -f1)" -gt \
          "$(printf '%s\n' "$LAST_STDERR" | grep -n 'Validating against' | head -1 | cut -d: -f1)" ]]; then
        pass "sources announced before the build"
    else
        fail "sources announced before the build" "Validating against must precede Building lines"
    fi
}

test_validate_crd_schema_dir_explicit() {
    run_fluxview validate --path "$CLUSTER_PATH" --schema-dir "$SCHEMA_DIR"
    assert_exit_code 0 "validate with explicit --schema-dir succeeds"
    assert_stderr_contains "Validating against $SCHEMA_DIR" "stderr mentions schema dir"
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

# ─── Native Kubernetes resources (default registry) ──────────────────────

test_validate_native_k8s_invalid() {
    # k8s/invalid/ holds a Deployment with replicas: "three" — a type
    # violation against the apps/v1 Deployment schema from the default
    # registry (downloaded on first use and cached).
    run_fluxview validate --path "$INVALID_CLUSTER_PATH"
    assert_exit_code 3 "invalid native resource exits 3"
    assert_stderr_contains "Deployment invalid/bad-deployment" "stderr reports the bad Deployment"
    assert_stderr_contains "/spec/replicas" "stderr mentions the replicas field"
}

test_validate_schema_cache_populated() {
    # Downloaded schemas are cached under $XDG_CACHE_HOME/fluxview/schemas;
    # isolate the cache and verify a run with native resources fills it.
    local xdg
    xdg=$(mktemp -d)
    XDG_CACHE_HOME="$xdg" run_fluxview validate --path "$CLUSTER_PATH"
    assert_exit_code 0 "validate with isolated cache succeeds"
    if [[ -d "$xdg/fluxview/schemas" ]] && [[ -n "$(ls -A "$xdg/fluxview/schemas" 2>/dev/null)" ]]; then
        pass "schema cache populated under XDG_CACHE_HOME"
    else
        fail "schema cache populated under XDG_CACHE_HOME" "$xdg/fluxview/schemas is missing or empty"
    fi
    rm -rf "$xdg"
}

test_validate_kubernetes_version_flag() {
    # An older but real Kubernetes version: schemas resolve for it too.
    run_fluxview validate --path "$CLUSTER_PATH" --kubernetes-version 1.30.0
    assert_exit_code 0 "validate with --kubernetes-version 1.30.0 succeeds"
    assert_stderr_contains "(Kubernetes 1.30.0)" "stderr shows the requested version"
}

test_validate_bogus_version_skips_native() {
    # Known behavior: an unknown Kubernetes version yields 404 from the
    # registry, which counts as "schema not found" — native resources are
    # silently skipped, not failed.
    run_fluxview validate --path "$CLUSTER_PATH" --kubernetes-version 0.0.0
    assert_exit_code 0 "unknown k8s version skips native resources (exit 0)"
    assert_stderr_contains "All resources valid." "no hard failure on unknown version"
}

# ─── CRD schema violations ───────────────────────────────────────────────

test_validate_invalid_resources_exit_3() {
    # k8s/invalid/ holds a Widget with size=250 (max 100) and color=purple
    # (not in enum) — both violate the CRD YAML schema from schemas/.
    run_fluxview validate --path "$INVALID_CLUSTER_PATH"
    assert_exit_code 3 "validate with invalid resources exits 3"
    assert_stderr_contains "Widget invalid/bad-widget" "stderr reports the bad Widget"
    assert_stderr_contains "/spec/size" "stderr mentions size field"
    assert_stderr_contains "/spec/color" "stderr mentions color field"
}

test_validate_invalid_lists_errors() {
    run_fluxview validate --path "$INVALID_CLUSTER_PATH"
    assert_exit_code 3 "validate exits 3 for invalid resources"
    assert_stderr_contains "maximum: got 250, want 100" "stderr shows the maximum violation"
    assert_stderr_contains "value must be one of" "stderr shows the enum violation"
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
    # Point validate at a directory with no schemas at all. Resources
    # without a matching schema are silently skipped — the CRD-sourced
    # Widget is not validated, native kinds still come from the registry.
    local empty_schemas
    empty_schemas=$(mktemp -d)
    run_fluxview validate --path "$CLUSTER_PATH" --schema-dir "$empty_schemas"
    assert_exit_code 0 "validate with no CRD schemas succeeds"
    assert_stderr_contains "All resources valid." "resources without schemas are skipped"
    rm -rf "$empty_schemas"
}

test_validate_yaml_crd_schema_format() {
    # The schemas/ directory contains both JSON schemas (.json) and a YAML CRD
    # (widgets-crd.yaml). Verify the YAML CRD is converted and applied: the
    # bad-widget scenario above fails only if the Widget schema is active.
    run_fluxview validate --path "$INVALID_CLUSTER_PATH"
    assert_exit_code 3 "YAML CRD schema is applied to Widgets"
    assert_stderr_contains "Widget invalid/bad-widget" "Widget validated via converted CRD YAML"
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
    assert_stdout_contains "--kubernetes-version" "help lists --kubernetes-version"
}

test_validate_old_crd_schema_dir_flag_rejected() {
    # --schema-dir is the canonical name (it never changed on main);
    # --crd-schema-dir existed only on the unreleased feature branch and
    # must be rejected, not silently ignored.
    run_fluxview validate --path "$CLUSTER_PATH" --crd-schema-dir "$SCHEMA_DIR"
    assert_exit_code 2 "unknown --crd-schema-dir flag is rejected"
    assert_contains "unknown flag" "error mentions unknown flag"
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
test_case "validate_announces_sources"           test_validate_announces_sources_before_build
test_case "validate_crd_schema_dir_explicit"     test_validate_crd_schema_dir_explicit
test_case "validate_namespace_filter"            test_validate_namespace_filter
test_case "validate_namespace_no_match"          test_validate_namespace_no_match
test_case "validate_native_k8s_invalid"          test_validate_native_k8s_invalid
test_case "validate_schema_cache_populated"      test_validate_schema_cache_populated
test_case "validate_kubernetes_version_flag"     test_validate_kubernetes_version_flag
test_case "validate_bogus_version_skips_native"  test_validate_bogus_version_skips_native
test_case "validate_invalid_exit_3"              test_validate_invalid_resources_exit_3
test_case "validate_invalid_lists_errors"        test_validate_invalid_lists_errors
test_case "validate_invalid_only_bad_resource"   test_validate_invalid_only_bad_resource
test_case "validate_missing_schema_skipped"      test_validate_missing_schema_skipped
test_case "validate_yaml_crd_schema_format"      test_validate_yaml_crd_schema_format
test_case "validate_nonexistent_path"            test_validate_nonexistent_path
test_case "validate_path_without_kustomizations" test_validate_path_without_kustomizations
test_case "validate_help"                        test_validate_help
test_case "validate_old_flag_rejected"           test_validate_old_crd_schema_dir_flag_rejected
test_case "validate_relative_path_no_warnings"   test_validate_relative_path_no_warnings
