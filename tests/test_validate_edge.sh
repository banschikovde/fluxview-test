#!/usr/bin/env bash
# Edge-case smoke tests for `fluxview validate` (kubeconform engine).
#
# Covers the fixture families under k8s/edge/:
#   - sparse resource files: an empty file, a file of only "---"
#     separators, a comment-only file (no YAML documents at all);
#   - multi-document YAML: every document in one file is validated;
#   - a CRD whose version ships no structural schema (the on-the-fly
#     CRD→schema converter skips it — the resource is then skipped);
#   - syntactically broken YAML (documents a known gap, see the case).
source "$(dirname "${BASH_SOURCE[0]}")/lib/framework.sh"

readonly EDGE_CLUSTER_PATH="$REPO_ROOT/k8s/edge/cluster"
readonly EDGE_INVALID_CLUSTER_PATH="$REPO_ROOT/k8s/edge/invalid/cluster"
readonly EDGE_BROKEN_CLUSTER_PATH="$REPO_ROOT/k8s/edge/broken/cluster"
readonly EDGE_CRD_DIR="$REPO_ROOT/k8s/edge/crds"

# ─── Sparse / empty files ────────────────────────────────────────────────

test_validate_edge_sparse_files() {
    # k8s/edge/resources holds an empty file, a "---"-only file and a
    # comment-only file next to normal resources. None of these produce
    # validation errors: kustomize drops them and validate exits 0.
    run_fluxview validate --path "$EDGE_CLUSTER_PATH"
    assert_exit_code 0 "empty/separator/comment-only files do not fail validate"
    assert_stderr_contains "All resources valid." "sparse files validate cleanly"
    assert_not_contains "malformed resource" "no resource is reported as malformed"
}

# ─── Multi-document YAML ─────────────────────────────────────────────────

test_validate_edge_multidoc_all_docs_validated() {
    # A multi-doc file whose SECOND document violates the ConfigMap schema
    # (integer data value). Every document must be validated: the failure
    # must name bad-second-doc while the valid first document stays clean.
    run_fluxview validate --path "$EDGE_INVALID_CLUSTER_PATH"
    assert_exit_code 3 "invalid second document in a multi-doc file exits 3"
    assert_stderr_contains "ConfigMap bad-second-doc" "stderr flags the second document"
    assert_stderr_contains "/data/key" "stderr points at the violated field"
    assert_not_contains "good-first-doc" "the valid first document is not flagged"
}

# ─── CRD without a structural schema ─────────────────────────────────────

test_validate_edge_crd_without_schema_skips_kind() {
    # k8s/edge/crds holds a CRD whose served version declares no
    # openAPIV3Schema: the converter writes no schema for it, so the Gadget
    # resource stays schema-less and is silently skipped (documented
    # behavior of IgnoreMissingSchemas) instead of failing the run.
    run_fluxview validate --path "$EDGE_CLUSTER_PATH" --crd-schema-dir "$EDGE_CRD_DIR"
    assert_exit_code 0 "schema-less CRD version does not fail validate"
    assert_stderr_contains "All resources valid." "resource without a CRD schema is skipped"
    assert_not_contains "Gadget" "the schema-less kind is not reported"
}

# ─── Broken YAML fails the gate ──────────────────────────────────────────

test_validate_edge_broken_yaml_fails() {
    # Since the build-failure fix (feature/validate-kubeconform), a
    # syntactically invalid resource file makes the kustomize build fail and
    # validate exits 2 instead of silently validating an empty set.
    run_fluxview validate --path "$EDGE_BROKEN_CLUSTER_PATH"
    assert_exit_code 2 "broken YAML fails validate (exit 2)"
    assert_stderr_contains "kustomize build failed for 1 path(s), cannot validate" "stderr reports the failed build"
    assert_not_contains "All resources valid." "no success message on a failed build"
}

# ─── Registration ────────────────────────────────────────────────────────

test_case "validate_edge_sparse_files"           test_validate_edge_sparse_files
test_case "validate_edge_multidoc"               test_validate_edge_multidoc_all_docs_validated
test_case "validate_edge_crd_without_schema"     test_validate_edge_crd_without_schema_skips_kind
test_case "validate_edge_broken_yaml_fails"      test_validate_edge_broken_yaml_fails
