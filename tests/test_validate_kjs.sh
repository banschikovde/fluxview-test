#!/usr/bin/env bash
# Smoke tests for the kubernetes-json-schema checkout format of
# --crd-schema-dir (the third schema-dir format): dirs named
# v<version>-standalone[-strict] in or one level under the schema dir
# validate native kinds locally, ahead of the default HTTP registry.
#
# Detection is proven with a marker schema that requires a field no real
# resource has ('markerFieldFromLocalCheckout'): a failure naming it means
# the LOCAL schema was applied; absence of the error means the registry
# (or nothing) was used instead.
source "$(dirname "${BASH_SOURCE[0]}")/lib/framework.sh"

readonly EDGE_CLUSTER_PATH="$REPO_ROOT/k8s/edge/cluster"
readonly KJS_DIR="$REPO_ROOT/k8s/edge/schema-dirs/kjs"
readonly KJS_NO_V_DIR="$REPO_ROOT/k8s/edge/schema-dirs/kjs-no-v"

test_validate_kjs_checkout_wins_over_registry() {
    # The marker schema in v1.36.1-standalone/ must be applied to the
    # edge cluster's ConfigMap: local checkout has priority over the
    # default registry. Other native kinds (Namespace, Secret) are not in
    # the checkout and fall back to the registry.
    run_fluxview validate --path "$EDGE_CLUSTER_PATH" --crd-schema-dir "$KJS_DIR"
    assert_exit_code 3 "marker schema from the local checkout fails the ConfigMap"
    assert_stderr_contains "ConfigMap edge/edge-multi-cm" "the ConfigMap is flagged"
    assert_stderr_contains "missing property 'markerFieldFromLocalCheckout'" "the LOCAL checkout schema was applied, not the registry's"
}

test_validate_kjs_fallback_to_registry() {
    # --kubernetes-version 1.35.0 has no v1.35.0-standalone/ dir in the
    # checkout: native kinds must gracefully fall back to the default
    # registry (real schemas) and pass.
    run_fluxview validate --path "$EDGE_CLUSTER_PATH" --crd-schema-dir "$KJS_DIR" --kubernetes-version 1.35.0
    assert_exit_code 0 "missing version dir falls back to the registry"
    assert_stderr_contains "All resources valid." "no marker error via registry schemas"
    assert_not_contains "markerFieldFromLocalCheckout" "the local checkout schema was NOT applied"
}

test_validate_kjs_dir_requires_v_prefix() {
    # Pinned nuance: NormalizedKubernetesVersion resolves with a "v"
    # prefix, so a checkout dir named 1.36.1-standalone (no "v") is a
    # silent miss — the marker schema must not apply and validation falls
    # back to the registry.
    run_fluxview validate --path "$EDGE_CLUSTER_PATH" --crd-schema-dir "$KJS_NO_V_DIR"
    assert_exit_code 0 "no-v checkout dir falls back to the registry"
    assert_stderr_contains "All resources valid." "registry schemas apply"
    assert_not_contains "markerFieldFromLocalCheckout" "the no-v checkout schema was NOT applied"
}

# ─── Registration ────────────────────────────────────────────────────────

test_case "validate_kjs_checkout_wins"         test_validate_kjs_checkout_wins_over_registry
test_case "validate_kjs_fallback_registry"     test_validate_kjs_fallback_to_registry
test_case "validate_kjs_dir_requires_v_prefix" test_validate_kjs_dir_requires_v_prefix
