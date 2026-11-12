#!/usr/bin/env bash
# Smoke tests for `fluxview build hr`.
#
# Verifies Helm chart inflation: OCIRepository (podinfo), local GitRepository
# chart (backend), graceful skipping of unsupported sources (Bucket, HelmChart
# chartRef), suspended HelmReleases, and name/namespace filters.

source "$(dirname "${BASH_SOURCE[0]}")/lib/framework.sh"

# ─── Happy paths ─────────────────────────────────────────────────────────

test_build_hr_default() {
    run_fluxview build hr --path "$CLUSTER_PATH"
    assert_exit_code 0 "build hr succeeds"
    # Both backend (GitRepository chart) and podinfo (OCIRepository) inflate.
    assert_stdout_contains "Deployment: backend" "backend chart inflated"
    assert_stdout_contains "Deployment: podinfo" "podinfo chart inflated"
    assert_stderr_contains "Inflating HelmRelease backend/backend" "stderr reports backend inflation"
    assert_stderr_contains "Inflating HelmRelease podinfo/podinfo" "stderr reports podinfo inflation"
}

test_build_hr_alias_helmrelease() {
    run_fluxview build helmrelease --path "$CLUSTER_PATH"
    assert_exit_code 0 "build helmrelease alias works"
    assert_stdout_contains "Deployment: podinfo" "alias produces same output"
}

test_build_hr_by_name() {
    run_fluxview build hr backend --path "$CLUSTER_PATH"
    assert_exit_code 0 "build hr backend succeeds"
    assert_stdout_contains "Deployment: backend" "backend chart inflated by name"
    assert_not_contains "Deployment: podinfo" "podinfo not inflated when name filter set"
}

test_build_hr_by_name_podinfo() {
    run_fluxview build hr podinfo --path "$CLUSTER_PATH"
    assert_exit_code 0 "build hr podinfo succeeds"
    assert_stdout_contains "Deployment: podinfo" "podinfo chart inflated"
    assert_not_contains "Deployment: backend" "backend excluded by name filter"
}

test_build_hr_namespace_filter() {
    run_fluxview build hr --path "$CLUSTER_PATH" --namespace backend
    assert_exit_code 0 "build hr --namespace backend succeeds"
    assert_stdout_contains "Deployment: backend" "backend present in backend ns"
    assert_not_contains "Deployment: podinfo" "podinfo in podinfo ns excluded"
}

test_build_hr_namespace_shorthand() {
    run_fluxview build hr --path "$CLUSTER_PATH" -n podinfo
    assert_exit_code 0 "build hr -n podinfo succeeds"
    assert_stdout_contains "Service: podinfo" "podinfo Service present"
    assert_not_contains "Deployment: backend" "backend excluded"
}

test_build_hr_skip_crds() {
    run_fluxview build hr --path "$CLUSTER_PATH" --skip-crds
    assert_exit_code 0 "build hr --skip-crds succeeds"
    assert_not_contains "kind: CustomResourceDefinition" "no CRDs in output"
    assert_stdout_contains "Deployment: podinfo" "non-CRD resources present"
}

test_build_hr_strip_attrs() {
    run_fluxview build hr --path "$CLUSTER_PATH" --strip-attrs helm.sh/chart
    assert_exit_code 0 "build hr --strip-attrs succeeds"
    assert_not_contains "helm.sh/chart:" "helm.sh/chart attr stripped"
    assert_stdout_contains "Deployment: podinfo" "Deployment still present"
}

test_build_hr_local_chart_values() {
    # backend HelmRelease overrides replicaCount and image.tag in values;
    # verify the inflation actually applies HelmRelease values over chart defaults.
    run_fluxview build hr backend --path "$CLUSTER_PATH"
    assert_exit_code 0 "build hr backend succeeds"
    assert_stdout_contains "replicas: 5" "HelmRelease replicaCount override applied"
    assert_stdout_contains "image: nginx:1.27" "HelmRelease image.tag override applied"
}

test_build_hr_podinfo_postrender_replicas() {
    # podinfo helmrelease.yaml has postRenderers forcing replicas=3.
    run_fluxview build hr podinfo --path "$CLUSTER_PATH"
    assert_exit_code 0 "build hr podinfo succeeds"
    assert_stdout_contains "replicas: 3" "postRenderers kustomize patch applied"
}

test_build_hr_boxed_output() {
    run_fluxview build hr backend --path "$CLUSTER_PATH"
    assert_exit_code 0 "build hr backend succeeds"
    assert_regex -- '-+ Deployment: backend -+' "box header for Deployment"
}

# ─── Unsupported / suspended scenarios (graceful skip) ───────────────────

test_build_hr_bucket_skipped() {
    run_fluxview build hr --path "$CLUSTER_PATH"
    assert_exit_code 0 "build hr succeeds even with unsupported HRs"
    assert_stderr_contains "Bucket-sourced chart for HelmRelease bucket-app" "Bucket HR skipped with warning"
    assert_not_contains "Deployment: bucket-app" "Bucket HR not inflated"
}

test_build_hr_helmchart_chartref_skipped() {
    run_fluxview build hr --path "$CLUSTER_PATH"
    assert_exit_code 0 "build hr succeeds"
    assert_stderr_contains "HelmRelease helmchart-hr/helmchart-hr has no chart name" "HelmChart chartRef skipped"
    assert_not_contains "Deployment: helmchart-hr" "HelmChart HR not inflated"
}

test_build_hr_suspended_skipped() {
    run_fluxview build hr --path "$CLUSTER_PATH"
    assert_exit_code 0 "build hr succeeds"
    assert_stderr_contains "Skipping suspended HelmRelease suspended-hr/suspended-hr" "suspended HR skipped"
    assert_not_contains "Deployment: suspended-hr" "suspended HR not inflated"
}

test_build_hr_dedup_duplicate_helmreleases() {
    # The repo has fake-podinfo/ that creates a duplicate (same ns/name) HelmRelease.
    # Verify dedup actually happens: only ONE podinfo Deployment in output.
    run_fluxview build hr podinfo --path "$CLUSTER_PATH"
    assert_exit_code 0 "build hr podinfo succeeds"
    local count
    count=$(printf '%s' "$LAST_STDOUT" | grep -c 'Deployment: podinfo')
    if [[ "$count" == "1" ]]; then
        pass "duplicate HelmRelease deduped (1 of $count)"
    else
        fail "duplicate HelmRelease deduped" "expected 1 occurrence, got $count"
    fi
}

# ─── Error paths ─────────────────────────────────────────────────────────

test_build_hr_unknown_name() {
    run_fluxview build hr nonexistent-hr --path "$CLUSTER_PATH"
    # buildHRInflation returns an error if name filter produces no matches.
    assert_exit_code 2 "unknown HR name fails"
    assert_stderr_contains "not found" "error reports not found"
}

# ─── --kubernetes-version (issue #14: kubeVersion-capped charts) ──────────

test_build_hr_kube_cap_below_sdk_default() {
    # rancher 2.15.x shape: a chart capped below the Helm SDK's own moving
    # default (derived from client-go) must render against the assumed
    # default without any flag.
    run_fluxview build hr capped-rancher --path "$REPO_ROOT/k8s/edge/kube-cap/cluster"
    assert_exit_code 0 "build hr of a kubeVersion-capped chart succeeds"
    assert_stdout_contains "Deployment: kube-cap/capped-rancher" "rancher-shaped capped chart inflated"
}

test_build_hr_kube_cap_default_skips() {
    # a chart capped below the assumed default (1.36.1) is warning + skip
    # (build never exits non-zero for a skippable HR).
    run_fluxview build hr capped-old --path "$REPO_ROOT/k8s/edge/kube-cap/cluster"
    assert_exit_code 0 "build hr degrades to warning + skip"
    assert_stderr_contains "kubeVersion" "cap failure is reported"
    assert_not_contains "Deployment: kube-cap/capped-old" "capped chart not rendered at the assumed default"
}

test_build_hr_kube_version_override() {
    run_fluxview build hr capped-old --path "$REPO_ROOT/k8s/edge/kube-cap/cluster" --kubernetes-version 1.28.9
    assert_exit_code 0 "build hr with --kubernetes-version override succeeds"
    assert_stdout_contains "Deployment: kube-cap/capped-old" "capped chart renders against 1.28.9"
}

test_build_hr_kube_version_env() {
    FLUXVIEW_KUBE_VERSION=1.28.9 run_fluxview build hr capped-old --path "$REPO_ROOT/k8s/edge/kube-cap/cluster"
    assert_exit_code 0 "build hr honors FLUXVIEW_KUBE_VERSION"
    assert_stdout_contains "Deployment: kube-cap/capped-old" "env-driven kube version renders the capped chart"
}

test_build_hr_kube_version_invalid() {
    run_fluxview build hr capped-old --path "$REPO_ROOT/k8s/edge/kube-cap/cluster" --kubernetes-version nonsense
    assert_exit_code 2 "invalid --kubernetes-version fails"
    assert_stderr_contains "invalid --kubernetes-version" "error names the flag"
}

test_build_hr_help() {
    run_fluxview build hr --help
    assert_exit_code 0 "build hr --help succeeds"
    assert_stdout_contains "Usage:" "help shows usage"
    assert_stdout_contains "helmrelease" "help mentions helmrelease alias"
}

# ─── Registration ────────────────────────────────────────────────────────

test_case "build_hr_default"                  test_build_hr_default
test_case "build_hr_alias_helmrelease"        test_build_hr_alias_helmrelease
test_case "build_hr_by_name"                  test_build_hr_by_name
test_case "build_hr_by_name_podinfo"          test_build_hr_by_name_podinfo
test_case "build_hr_namespace_filter"         test_build_hr_namespace_filter
test_case "build_hr_namespace_shorthand"      test_build_hr_namespace_shorthand
test_case "build_hr_skip_crds"                test_build_hr_skip_crds
test_case "build_hr_strip_attrs"              test_build_hr_strip_attrs
test_case "build_hr_local_chart_values"       test_build_hr_local_chart_values
test_case "build_hr_postrender_replicas"      test_build_hr_podinfo_postrender_replicas
test_case "build_hr_boxed_output"             test_build_hr_boxed_output
test_case "build_hr_bucket_skipped"           test_build_hr_bucket_skipped
test_case "build_hr_helmchart_chartref_skipped" test_build_hr_helmchart_chartref_skipped
test_case "build_hr_suspended_skipped"        test_build_hr_suspended_skipped
test_case "build_hr_dedup_duplicate"          test_build_hr_dedup_duplicate_helmreleases
test_case "build_hr_unknown_name"             test_build_hr_unknown_name
test_case "build_hr_help"                     test_build_hr_help
test_case "build_hr_kube_cap_below_sdk_default" test_build_hr_kube_cap_below_sdk_default
test_case "build_hr_kube_cap_default_skips"   test_build_hr_kube_cap_default_skips
test_case "build_hr_kube_version_override"    test_build_hr_kube_version_override
test_case "build_hr_kube_version_env"         test_build_hr_kube_version_env
test_case "build_hr_kube_version_invalid"     test_build_hr_kube_version_invalid
