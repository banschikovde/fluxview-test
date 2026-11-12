#!/usr/bin/env bash
# Smoke tests for `fluxview inventory`.
#
# Inventory has no other scenarios yet — this file covers the flag wiring and
# the --kubernetes-version knob (issue #14): charts with an upper kubeVersion
# bound must render (their IMAGES column resolve), the flag overrides the
# assumed version, and an unusable value fails with exit 2.

source "$(dirname "${BASH_SOURCE[0]}")/lib/framework.sh"

readonly KUBE_CAP_CLUSTER_PATH="$REPO_ROOT/k8s/edge/kube-cap/cluster"

# ─── --kubernetes-version ────────────────────────────────────────────────

test_inventory_kube_cap_default() {
    # capped-dist (< 1.37.0-0, a chart pinned to older clusters) renders
    # against the assumed default without any flag; capped-old (< 1.29.0-0)
    # cannot render and is skipped with a warning.
    run_fluxview inventory --path "$KUBE_CAP_CLUSTER_PATH"
    assert_exit_code 0 "inventory succeeds over kubeVersion-capped charts"
    assert_stdout_contains "capped-dist" "upper-bound capped chart listed"
    assert_stderr_contains "kubeVersion" "chart capped below the assumed default warns"
}

test_inventory_kube_version_override() {
    run_fluxview inventory --path "$KUBE_CAP_CLUSTER_PATH" --kubernetes-version 1.28.9
    assert_exit_code 0 "inventory with --kubernetes-version override succeeds"
    assert_stdout_contains "capped-old" "chart capped below the default now listed"
    assert_stdout_contains "capped-dist" "upper-bound capped chart still listed"
}

test_inventory_kube_version_invalid() {
    run_fluxview inventory --path "$KUBE_CAP_CLUSTER_PATH" --kubernetes-version nonsense
    assert_exit_code 2 "invalid --kubernetes-version fails"
    assert_stderr_contains "invalid --kubernetes-version" "error names the flag"
}

# ─── Flag registration ───────────────────────────────────────────────────

test_inventory_kube_version_flag_registered() {
    run_fluxview inventory --help
    assert_exit_code 0 "inventory --help succeeds"
    assert_stdout_contains "--kubernetes-version" "flag registered"
}

# ─── Registration ────────────────────────────────────────────────────────

test_case "inventory_kube_cap_default"          test_inventory_kube_cap_default
test_case "inventory_kube_version_override"     test_inventory_kube_version_override
test_case "inventory_kube_version_invalid"      test_inventory_kube_version_invalid
test_case "inventory_kube_version_registered"   test_inventory_kube_version_flag_registered
