#!/usr/bin/env bash
# Smoke tests for `fluxview build ks`.
#
# Verifies building Kustomization resources: default, name/namespace filters,
# --skip-crds, --strip-attrs, aliases, and error paths.

source "$(dirname "${BASH_SOURCE[0]}")/lib/framework.sh"

# ─── Happy paths ─────────────────────────────────────────────────────────

test_build_ks_default() {
    run_fluxview build ks --path "$CLUSTER_PATH"
    assert_exit_code 0 "build ks succeeds"
    assert_stdout_contains "ConfigMap: infra/infra-settings" "output includes infra ConfigMap"
    assert_stdout_contains "HelmRelease: podinfo/podinfo" "output includes podinfo HelmRelease"
    assert_stdout_contains "CustomResourceDefinition: widgets.example.io" "output includes CRD"
    assert_stdout_contains "Widget: infra/my-widget" "output includes custom Widget resource"
    assert_stderr_contains "Building flux-system/apps" "stderr reports building apps KS"
    assert_stderr_contains "Building flux-system/crds" "stderr reports building crds KS"
    assert_stderr_contains "Building flux-system/infra" "stderr reports building infra KS"
}

test_build_ks_alias_kustomization() {
    run_fluxview build kustomization --path "$CLUSTER_PATH"
    assert_exit_code 0 "build kustomization alias works"
    assert_stdout_contains "HelmRelease: podinfo/podinfo" "alias produces same output"
}

test_build_ks_by_name_apps() {
    run_fluxview build ks apps --path "$CLUSTER_PATH"
    assert_exit_code 0 "build ks <name> succeeds"
    assert_stdout_contains "HelmRelease: podinfo/podinfo" "filtered build includes podinfo HR"
    assert_not_contains "ConfigMap: infra/infra-settings" "filtered build excludes infra resources"
}

test_build_ks_by_name_crds() {
    run_fluxview build ks crds --path "$CLUSTER_PATH"
    assert_exit_code 0 "build ks crds succeeds"
    assert_stdout_contains "CustomResourceDefinition: widgets.example.io" "crds build includes Widget CRD"
}

test_build_ks_namespace_filter() {
    run_fluxview build ks --path "$CLUSTER_PATH" --namespace podinfo
    assert_exit_code 0 "build ks --namespace podinfo succeeds"
    assert_stdout_contains "HelmRelease: podinfo/podinfo" "podinfo HR is in podinfo ns"
    assert_not_contains "ConfigMap: infra/infra-settings" "infra resources excluded by ns filter"
}

test_build_ks_namespace_filter_flux_system() {
    run_fluxview build ks --path "$CLUSTER_PATH" --namespace flux-system
    assert_exit_code 0 "build ks --namespace flux-system succeeds"
    assert_stdout_contains "ConfigMap: flux-system/cluster-settings" "flux-system ConfigMap present"
    assert_not_contains "HelmRelease: podinfo/podinfo" "podinfo excluded by ns filter"
}

test_build_ks_namespace_shorthand() {
    run_fluxview build ks --path "$CLUSTER_PATH" -n infra
    assert_exit_code 0 "build ks -n infra (short flag) succeeds"
    assert_stdout_contains "ConfigMap: infra/infra-settings" "infra ConfigMap present"
    assert_not_contains "HelmRelease: podinfo/podinfo" "podinfo excluded"
}

test_build_ks_skip_crds() {
    run_fluxview build ks --path "$CLUSTER_PATH" --skip-crds
    assert_exit_code 0 "build ks --skip-crds succeeds"
    assert_not_contains "CustomResourceDefinition:" "CRD resources excluded"
    assert_stdout_contains "HelmRelease: podinfo/podinfo" "non-CRD resources still present"
}

test_build_ks_strip_attrs() {
    # helm.sh/chart and status are common noise attrs; verify stripping works.
    run_fluxview build ks --path "$CLUSTER_PATH" --strip-attrs status,helm.sh/chart
    assert_exit_code 0 "build ks --strip-attrs succeeds"
    assert_not_contains "helm.sh/chart" "helm.sh/chart attr is stripped"
    # 'status' as a top-level key should be gone from infra Deployment.
    assert_stdout_contains "kind: Deployment" "Deployment still present"
}

test_build_ks_path_shorthand() {
    run_fluxview build ks -p "$CLUSTER_PATH"
    assert_exit_code 0 "build ks -p (short flag) succeeds"
    assert_stdout_contains "HelmRelease: podinfo/podinfo" "output present"
}

test_build_ks_boxed_output_format() {
    run_fluxview build ks --path "$CLUSTER_PATH" --namespace infra
    assert_exit_code 0 "build ks namespace infra succeeds"
    # Box format is a 3-line block: dashes, " Kind: ns/name", dashes.
    # The header line starts with a leading space.
    assert_stdout_contains " ConfigMap: infra/infra-settings" "box header for ConfigMap"
    assert_stdout_contains " Deployment: infra/backend" "box header for Deployment"
}

test_build_ks_resource_sorting() {
    run_fluxview build ks --path "$CLUSTER_PATH" --namespace infra
    assert_exit_code 0 "namespace infra build succeeds"
    # Sorted by kind alphabetically: ConfigMap < Deployment < Namespace < Service < Widget.
    local cm_line dep_line
    cm_line=$(printf '%s' "$LAST_STDOUT" | grep -n 'ConfigMap: infra/infra-settings' | head -1 | cut -d: -f1)
    dep_line=$(printf '%s' "$LAST_STDOUT" | grep -n 'Deployment: infra/backend' | head -1 | cut -d: -f1)
    if [[ -n "$cm_line" && -n "$dep_line" && "$cm_line" -lt "$dep_line" ]]; then
        pass "resources sorted by kind (ConfigMap before Deployment)"
    else
        fail "resources sorted by kind" "ConfigMap at line $cm_line, Deployment at line $dep_line"
    fi
}

# ─── Error paths ─────────────────────────────────────────────────────────

test_build_ks_no_resource_type() {
    run_fluxview build --path "$CLUSTER_PATH"
    assert_exit_code 2 "build without resource type fails"
    assert_stderr_contains "resource type required" "error message explains required arg"
}

test_build_ks_unsupported_resource_type() {
    run_fluxview build foo --path "$CLUSTER_PATH"
    assert_exit_code 2 "unsupported resource type fails"
    assert_stderr_contains "unsupported resource type" "error mentions unsupported type"
}

test_build_ks_nonexistent_path() {
    run_fluxview build ks --path "/tmp/does-not-exist-$$"
    assert_exit_code 2 "nonexistent path fails"
    assert_stderr_contains "does not exist" "error reports missing path"
}

test_build_ks_path_without_kustomizations() {
    # A directory inside the repo that has no Flux Kustomization files
    # (only native kustomization.yaml, which is excluded by hasDirectKustomizations).
    run_fluxview build ks --path "$REPO_ROOT/k8s/test/infra/"
    assert_exit_code 2 "path without Flux Kustomizations fails"
    assert_stderr_contains "no Kustomization files found" "error mentions no Kustomizations"
}

test_build_ks_unknown_name() {
    run_fluxview build ks nonexistent-ks --path "$CLUSTER_PATH"
    assert_exit_code 2 "unknown Kustomization name fails"
    assert_stderr_contains "not found" "error reports not found"
}

test_build_ks_namespace_no_match() {
    run_fluxview build ks --path "$CLUSTER_PATH" --namespace no-such-namespace
    assert_exit_code 0 "namespace filter with no match succeeds"
    assert_stderr_contains "No resources found in namespace" "stderr reports no resources"
}

# ─── Help ────────────────────────────────────────────────────────────────

test_build_ks_help() {
    run_fluxview build ks --help
    assert_exit_code 0 "build ks --help succeeds"
    assert_stdout_contains "Usage:" "help shows usage"
    assert_stdout_contains "--skip-crds" "help lists --skip-crds flag"
    assert_stdout_contains "--strip-attrs" "help lists --strip-attrs flag"
    assert_stdout_contains "--namespace" "help lists --namespace flag"
}

test_build_ks_default_path_is_cwd() {
    # When --path is omitted, fluxview uses CWD. Run from CLUSTER_PATH.
    local out err rc
    out=$(mktemp); err=$(mktemp)
    ( cd "$CLUSTER_PATH" && "$FLUXVIEW_BIN" build ks >"$out" 2>"$err" ); rc=$?
    LAST_STDOUT=$(<"$out"); LAST_STDERR=$(<"$err"); LAST_EXIT=$rc
    rm -f "$out" "$err"
    assert_exit_code 0 "build ks without --path uses CWD"
    assert_stdout_contains "HelmRelease: podinfo/podinfo" "output produced from CWD"
}

# ─── Registration ────────────────────────────────────────────────────────

test_case "build_ks_default"                 test_build_ks_default
test_case "build_ks_alias_kustomization"     test_build_ks_alias_kustomization
test_case "build_ks_by_name_apps"            test_build_ks_by_name_apps
test_case "build_ks_by_name_crds"            test_build_ks_by_name_crds
test_case "build_ks_namespace_filter"        test_build_ks_namespace_filter
test_case "build_ks_namespace_filter_flux"   test_build_ks_namespace_filter_flux_system
test_case "build_ks_namespace_shorthand"     test_build_ks_namespace_shorthand
test_case "build_ks_skip_crds"               test_build_ks_skip_crds
test_case "build_ks_strip_attrs"             test_build_ks_strip_attrs
test_case "build_ks_path_shorthand"          test_build_ks_path_shorthand
test_case "build_ks_boxed_output_format"     test_build_ks_boxed_output_format
test_case "build_ks_resource_sorting"        test_build_ks_resource_sorting
test_case "build_ks_no_resource_type"        test_build_ks_no_resource_type
test_case "build_ks_unsupported_type"        test_build_ks_unsupported_resource_type
test_case "build_ks_nonexistent_path"        test_build_ks_nonexistent_path
test_case "build_ks_path_without_kustomizations" test_build_ks_path_without_kustomizations
test_case "build_ks_unknown_name"            test_build_ks_unknown_name
test_case "build_ks_namespace_no_match"      test_build_ks_namespace_no_match
test_case "build_ks_help"                    test_build_ks_help
test_case "build_ks_default_path_is_cwd"     test_build_ks_default_path_is_cwd
