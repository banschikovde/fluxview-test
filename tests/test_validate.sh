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
readonly STRICT_CLUSTER_PATH="$REPO_ROOT/k8s/edge/strict/cluster"

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
    # Downloaded schemas are cached under $FLUXVIEW_CACHE_HOME/schemas;
    # isolate the cache and verify a run with native resources fills it.
    local base
    base=$(mktemp -d)
    FLUXVIEW_CACHE_HOME="$base" run_fluxview validate --path "$CLUSTER_PATH"
    assert_exit_code 0 "validate with isolated cache succeeds"
    if [[ -d "$base/schemas" ]] && [[ -n "$(ls -A "$base/schemas" 2>/dev/null)" ]]; then
        pass "schema cache populated under FLUXVIEW_CACHE_HOME"
    else
        fail "schema cache populated under FLUXVIEW_CACHE_HOME" "$base/schemas is missing or empty"
    fi
    rm -rf "$base"
}

test_validate_kubernetes_version_flag() {
    # An older but real Kubernetes version: schemas resolve for it too.
    run_fluxview validate --path "$CLUSTER_PATH" --kubernetes-version 1.30.0
    assert_exit_code 0 "validate with --kubernetes-version 1.30.0 succeeds"
    assert_stderr_contains "(Kubernetes 1.30.0)" "stderr shows the requested version"
}

test_validate_kubernetes_version_v_prefix() {
    # A version with the user-facing "v" prefix (v1.30.0) must behave
    # like 1.30.0: schemas resolve, and the announcement shows the
    # normalized form without the prefix.
    run_fluxview validate --path "$CLUSTER_PATH" --kubernetes-version v1.30.0
    assert_exit_code 0 "validate with --kubernetes-version v1.30.0 succeeds"
    assert_stderr_contains "(Kubernetes 1.30.0)" "stderr shows the normalized version"
}

test_validate_bogus_version_skips_native() {
    # Known behavior: an unknown Kubernetes version yields 404 from the
    # registry, which counts as "schema not found" — native resources are
    # silently skipped, not failed. The mass-skip warning must still hint
    # at the likely wrong --kubernetes-version.
    run_fluxview validate --path "$CLUSTER_PATH" --kubernetes-version 0.0.0
    assert_exit_code 0 "unknown k8s version skips native resources (exit 0)"
    assert_stderr_contains "All resources valid." "no hard failure on unknown version"
    assert_stderr_contains "Warning: the default registry has no schema" \
        "the mass-skip warning fires when every fetched kind 404s"
    assert_stderr_contains "a wrong --kubernetes-version is a common cause" \
        "the warning points at the likely cause"
}

test_validate_kubernetes_version_short_form_rejected() {
    # A short "1.30" would 404 every default-registry schema URL and
    # silently skip all native kinds, looking like a green run; it is
    # rejected before the build even starts.
    run_fluxview validate --path "$CLUSTER_PATH" --kubernetes-version 1.30
    assert_exit_code 2 "short kubernetes version rejected before the build"
    assert_stderr_contains "want a full version like 1.36.1 (or master)" \
        "error explains the expected form"
    assert_not_contains "Building " "no build happens for a rejected version"
}

test_validate_kubernetes_version_master() {
    # "master" is the registry's moving alias: schemas resolve like a
    # pinned release, and the announcement shows the normalized form.
    run_fluxview validate --path "$CLUSTER_PATH" --kubernetes-version master
    assert_exit_code 0 "master version validates against master-standalone"
    assert_stderr_contains "(Kubernetes master)" "announcement shows master"
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

# ─── Strict mode ─────────────────────────────────────────────────────────

test_validate_strict_off_accepts_unknown_fields() {
    # The edge/strict fixture holds a ConfigMap with a top-level unknown
    # field. Default (non-strict) standalone schemas from the registry
    # allow unknown fields — the run passes without --strict.
    run_fluxview validate --path "$STRICT_CLUSTER_PATH"
    assert_exit_code 0 "non-strict schemas accept unknown fields"
    assert_stderr_contains "All resources valid." "no failure without --strict"
}

test_validate_strict_rejects_unknown_fields() {
    # --strict switches the default registry to -standalone-strict
    # schemas: the same unknown field now fails validation.
    # (Duplicate YAML keys — the other half of --strict — are rejected by
    # the kustomize build already; see test_validate_edge.sh.)
    run_fluxview validate --path "$STRICT_CLUSTER_PATH" --strict
    assert_exit_code 3 "--strict rejects unknown fields (exit 3)"
    assert_stderr_contains "ConfigMap edge-strict/unknown-field-cm" "stderr names the offending ConfigMap"
    assert_stderr_contains "bogusTopLevel" "stderr names the unknown field"
}

# ─── Skip kinds ──────────────────────────────────────────────────────────

test_validate_skip_kind_comma_separated() {
    # k8s/invalid holds a bad Deployment and a bad Widget. Skipping both
    # kinds (comma-separated form) leaves only the valid Namespace —
    # validation passes.
    run_fluxview validate --path "$INVALID_CLUSTER_PATH" --skip-kind "Deployment,Widget"
    assert_exit_code 0 "comma-separated --skip-kind skips both invalid resources"
    assert_stderr_contains "All resources valid." "skipped kinds are not flagged"
}

test_validate_skip_kind_qualified_repeatable() {
    # The qualified apiVersion/Kind form plus repeatable flag usage:
    # example.io/v1alpha1/Widget skips only that apiVersion's Widget.
    run_fluxview validate --path "$INVALID_CLUSTER_PATH" \
        --skip-kind Deployment --skip-kind example.io/v1alpha1/Widget
    assert_exit_code 0 "qualified --skip-kind form skips the Widget"
    assert_stderr_contains "All resources valid." "the run passes with both kinds skipped"
}

# ─── Machine-readable output ─────────────────────────────────────────────

test_validate_output_json() {
    # --output json emits the full report to STDOUT (stderr keeps the
    # human chatter) and the exit code still reports validation failure.
    run_fluxview validate --path "$INVALID_CLUSTER_PATH" --output json
    assert_exit_code 3 "json output keeps the failure exit code"
    assert_stdout_contains "\"status\": \"invalid\"" "stdout carries per-resource statuses"
    assert_stdout_contains "\"kind\": \"Widget\"" "stdout names the resource kind"
    assert_stdout_contains "\"summary\"" "stdout carries the summary block"
    assert_stderr_contains "Validating against" "human chatter stays on stderr"
}

test_validate_output_junit() {
    # --output junit emits a JUnit XML report to stdout: invalid
    # resources become <failure> test cases for CI consumption.
    run_fluxview validate --path "$INVALID_CLUSTER_PATH" --output junit
    assert_exit_code 3 "junit output keeps the failure exit code"
    assert_stdout_contains "<testsuites" "stdout is a JUnit XML document"
    assert_stdout_contains "<failure" "invalid resources carry <failure> cases"
    assert_stderr_contains "Validating against" "human chatter stays on stderr"
}

test_validate_output_json_success_with_skipped() {
    # JSON output on a PASSING run: the edge cluster's Gadget has no schema
    # anywhere, so the report must carry per-resource statuses ("valid" and
    # "skipped") plus the summary counts — the CI-consumable positive path,
    # not just the failure report.
    run_fluxview validate --path "$REPO_ROOT/k8s/edge/cluster" \
        --schema-dir "$SCHEMA_DIR" --output json
    assert_exit_code 0 "json output on a passing run exits 0"
    assert_stdout_contains '"status": "valid"' "valid statuses are reported"
    assert_stdout_contains '"status": "skipped"' "schema-less Gadget is reported as skipped"
    assert_stdout_contains '"summary"' "stdout carries the summary block"
}

test_validate_output_junit_skipped_cases() {
    # JUnit output on a PASSING run: schema-less resources (the Gadget)
    # become <skipped> test cases with skipped counts on the suite, so CI
    # can distinguish "checked and clean" from "nothing to check".
    run_fluxview validate --path "$REPO_ROOT/k8s/edge/cluster" \
        --schema-dir "$SCHEMA_DIR" --output junit
    assert_exit_code 0 "junit output on a passing run exits 0"
    assert_stdout_contains '<skipped message="no schema or skipped kind">' "skipped testcase for the schema-less kind"
    assert_stdout_contains 'skipped="1"' "suite counts the skipped case"
    assert_not_contains "<failure" "no failure cases on a passing run"
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

# ─── Schema download timeout ─────────────────────────────────────────────

test_validate_schema_download_timeout_negative_rejected() {
    # The flag accepts 0 (no limit) or a positive duration; a negative
    # value is a configuration error, rejected before any work.
    run_fluxview validate --path "$CLUSTER_PATH" --schema-download-timeout -5s
    assert_exit_code 2 "negative --schema-download-timeout rejected"
    assert_stderr_contains "must be 0 (no limit) or a positive duration" \
        "error explains the accepted range"
}

test_validate_schema_download_timeout_zero_accepted() {
    # 0 means "no per-request limit": valid — the run proceeds (stays
    # interruptible via Ctrl-C) and behaves like the default.
    run_fluxview validate --path "$CLUSTER_PATH" --schema-download-timeout 0
    assert_exit_code 0 "zero --schema-download-timeout accepted"
    assert_stderr_contains "All resources valid." "run completes with no per-request limit"
}

# ─── Registration ────────────────────────────────────────────────────────

test_case "validate_happy"                       test_validate_happy
test_case "validate_announces_sources"           test_validate_announces_sources_before_build
test_case "validate_crd_schema_dir_explicit"     test_validate_crd_schema_dir_explicit
test_case "validate_namespace_filter"            test_validate_namespace_filter
test_case "validate_namespace_no_match"          test_validate_namespace_no_match
test_case "validate_native_k8s_invalid"          test_validate_native_k8s_invalid
test_case "validate_schema_cache_populated"      test_validate_schema_cache_populated
test_case "validate_kubernetes_version_flag"       test_validate_kubernetes_version_flag
test_case "validate_kubernetes_version_v_prefix"   test_validate_kubernetes_version_v_prefix
test_case "validate_kubernetes_version_short"      test_validate_kubernetes_version_short_form_rejected
test_case "validate_kubernetes_version_master"     test_validate_kubernetes_version_master
test_case "validate_bogus_version_skips_native"    test_validate_bogus_version_skips_native
test_case "validate_invalid_exit_3"              test_validate_invalid_resources_exit_3
test_case "validate_invalid_lists_errors"        test_validate_invalid_lists_errors
test_case "validate_invalid_only_bad_resource"   test_validate_invalid_only_bad_resource
test_case "validate_missing_schema_skipped"      test_validate_missing_schema_skipped
test_case "validate_yaml_crd_schema_format"      test_validate_yaml_crd_schema_format
test_case "validate_nonexistent_path"            test_validate_nonexistent_path
test_case "validate_path_without_kustomizations" test_validate_path_without_kustomizations
test_case "validate_help"                        test_validate_help
test_case "validate_old_flag_rejected"           test_validate_old_crd_schema_dir_flag_rejected
test_case "validate_relative_path_no_warnings"     test_validate_relative_path_no_warnings
test_case "validate_strict_off"                    test_validate_strict_off_accepts_unknown_fields
test_case "validate_strict_rejects_unknown"        test_validate_strict_rejects_unknown_fields
test_case "validate_skip_kind_comma"               test_validate_skip_kind_comma_separated
test_case "validate_skip_kind_qualified"           test_validate_skip_kind_qualified_repeatable
test_case "validate_output_json"                   test_validate_output_json
test_case "validate_output_junit"                   test_validate_output_junit
test_case "validate_output_json_success"           test_validate_output_json_success_with_skipped
test_case "validate_output_junit_skipped"          test_validate_output_junit_skipped_cases
test_case "validate_download_timeout_negative"     test_validate_schema_download_timeout_negative_rejected
test_case "validate_download_timeout_zero"         test_validate_schema_download_timeout_zero_accepted
