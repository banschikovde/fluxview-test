#!/usr/bin/env bash
# Edge-case smoke tests for `fluxview validate` (kubeconform engine).
#
# Covers the fixture families under k8s/edge/:
#   - sparse resource files: an empty file, a file of only "---"
#     separators, a comment-only file (no YAML documents at all);
#   - multi-document YAML: every document in one file is validated;
#   - a CRD whose version ships no structural schema (the on-the-fly
#     CRD→schema converter skips it — the resource is then skipped);
#   - syntactically broken YAML (fails the build, exit 2);
#   - duplicated mapping keys (the kustomize build rejects them before
#     kubeconform's --strict ever sees them);
#   - a multi-version CRD: each served version validated against its own
#     converted schema (and Flux-only uncovered kinds stay off the
#     mass-skip warning);
#   - a corrupt JSON schema file in --schema-dir (parse error, not skip);
#   - a Kustomization whose dir builds zero resources;
#   - a CRD file whose YAML cannot be decoded (hard error exit 2 — a
#     schema source must not break silently; the failure is never cached).
source "$(dirname "${BASH_SOURCE[0]}")/lib/framework.sh"

readonly EDGE_CLUSTER_PATH="$REPO_ROOT/k8s/edge/cluster"
readonly EDGE_INVALID_CLUSTER_PATH="$REPO_ROOT/k8s/edge/invalid/cluster"
readonly EDGE_BROKEN_CLUSTER_PATH="$REPO_ROOT/k8s/edge/broken/cluster"
readonly EDGE_BROKEN_PATH_CLUSTER="$REPO_ROOT/k8s/edge/broken-path/cluster"
readonly EDGE_CRD_DIR="$REPO_ROOT/k8s/edge/crds"
readonly EDGE_DUP_KEYS_CLUSTER_PATH="$REPO_ROOT/k8s/edge/dup-keys/cluster"
readonly EDGE_MULTIVERSION_CLUSTER_PATH="$REPO_ROOT/k8s/edge/multiversion-crd/cluster"
readonly EDGE_MULTIVERSION_CRD_DIR="$REPO_ROOT/k8s/edge/multiversion-crd/crds"
readonly EDGE_BROKEN_SCHEMA_DIR="$REPO_ROOT/k8s/edge/broken-schema"
readonly EDGE_EMPTY_CLUSTER_PATH="$REPO_ROOT/k8s/edge/empty/cluster"
readonly EDGE_BROKEN_CRD_DIR="$REPO_ROOT/k8s/edge/broken-crd/crds"

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
    run_fluxview validate --path "$EDGE_CLUSTER_PATH" --schema-dir "$EDGE_CRD_DIR"
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

# ─── Flux KS with a missing spec.path ────────────────────────────────────

test_validate_edge_missing_path_fails() {
    # A Flux Kustomization whose spec.path does not exist in the repo used
    # to be skipped silently — its resources were absent from the checked
    # set while validate reported success. Now validate warns and exits 2.
    run_fluxview validate --path "$EDGE_BROKEN_PATH_CLUSTER"
    assert_exit_code 2 "KS with missing spec.path fails validate (exit 2)"
    assert_stderr_contains "path ./k8s/test/does-not-exist not found locally" "warning names the missing path"
    assert_stderr_contains "1 Kustomization(s) point to a path missing from the repository, cannot validate" "stderr reports the Kustomization"
    assert_not_contains "All resources valid." "no success message on a missing spec.path"
}

# ─── Duplicate YAML keys ─────────────────────────────────────────────────

test_validate_edge_duplicate_keys_fail_build() {
    # A resource with a duplicated mapping key never reaches kubeconform:
    # the kustomize build (yaml.v3) rejects duplicate keys already in
    # lenient mode, so validate exits 2 on the failed build instead of 3
    # on a --strict schema violation. Known behavior: the build gate is
    # stricter than kubeconform's own --strict decoder for this case.
    run_fluxview validate --path "$EDGE_DUP_KEYS_CLUSTER_PATH"
    assert_exit_code 2 "duplicated YAML keys fail the kustomize build (exit 2)"
    assert_stderr_contains "kustomize build failed for 1 path(s), cannot validate" "stderr reports the failed build"
    assert_stderr_contains "already defined" "the warning names the duplicated key"
    assert_not_contains "All resources valid." "no success message on duplicated keys"
}

# ─── Multi-version CRD ───────────────────────────────────────────────────

test_validate_edge_multiversion_crd_per_version_schemas() {
    # The CRD ships two served versions with different constraints: the
    # same spec.size=50 is valid under v1alpha1 (max 100) and invalid
    # under v1beta1 (max 10). Each version must be validated against its
    # own converted schema (thing-multiversion-v1alpha1.json /
    # thing-multiversion-v1beta1.json): thing-new-bad is flagged while
    # thing-old-ok — the same value — stays clean.
    run_fluxview validate --path "$EDGE_MULTIVERSION_CLUSTER_PATH" \
        --schema-dir "$EDGE_MULTIVERSION_CRD_DIR"
    assert_exit_code 3 "v1beta1 violation fails, v1alpha1 does not (exit 3)"
    assert_stderr_contains "Thing edge/thing-new-bad" "stderr flags the v1beta1 resource"
    assert_stderr_contains "/spec/size: maximum: got 50, want 10" "the v1beta1 maximum (10) applies"
    assert_not_contains "thing-old-ok" "the v1alpha1 resource is not flagged (its schema allows 50)"
    # Every custom kind is locally covered; the only uncovered kind is the
    # Flux KS CR, which the registry never carries — the mass-skip warning
    # (a wrong --kubernetes-version hint) must stay silent.
    assert_not_contains "Warning: the default registry has no schema" \
        "Flux-only uncovered kinds do not trip the mass-skip warning"
}

# ─── Corrupt JSON schema file in --schema-dir ────────────────────────────

test_validate_edge_broken_schema_file_errors() {
    # A schema file that exists but is not valid JSON is a hard error for
    # the matching kind (status "error"), not a skip: the ConfigMaps of
    # the edge cluster fail with the JSON parse error and validate exits
    # 3 — a schema source must not break silently.
    run_fluxview validate --path "$EDGE_CLUSTER_PATH" --schema-dir "$EDGE_BROKEN_SCHEMA_DIR"
    assert_exit_code 3 "corrupt schema file fails the matching kind (exit 3)"
    assert_stderr_contains "ConfigMap edge/edge-multi-cm" "stderr flags the ConfigMap"
    assert_stderr_contains "invalid character" "stderr shows the JSON parse error"
    assert_not_contains "All resources valid." "no success message on a broken schema"
}

# ─── Zero-resource build ─────────────────────────────────────────────────

test_validate_edge_no_resources() {
    # A Kustomization whose spec.path builds zero resources (an empty
    # kustomization.yaml): only the Flux KS CR itself reaches validation.
    # The run must pass cleanly — no crash, no "malformed resource".
    run_fluxview validate --path "$EDGE_EMPTY_CLUSTER_PATH" --schema-dir "$REPO_ROOT/schemas"
    assert_exit_code 0 "empty resource set validates clean"
    assert_stderr_contains "All resources valid." "only the KS CR itself is validated"
    assert_not_contains "malformed resource" "no resource is reported as malformed"
}

# ─── Broken YAML CRD file in --schema-dir ────────────────────────────────

test_validate_edge_broken_crd_yaml_fails() {
    # A CRD file whose YAML cannot be decoded is a hard error: the kinds
    # it defines would silently lose validation — fail-closed, symmetric
    # with the corrupt JSON schema file above. The cache is isolated and
    # the failure is never cached: a warm second run fails identically
    # (no warn-once degradation to warn-never across cached runs).
    local xdg
    xdg=$(mktemp -d)
    XDG_CACHE_HOME="$xdg" run_fluxview validate --path "$EDGE_CLUSTER_PATH" \
        --schema-dir "$EDGE_BROKEN_CRD_DIR"
    assert_exit_code 2 "broken CRD YAML fails validate (exit 2)"
    assert_stderr_contains "could not decode a document in " "the error names the undecodable CRD file"
    assert_not_contains "All resources valid." "no success message on a broken CRD file"

    XDG_CACHE_HOME="$xdg" run_fluxview validate --path "$EDGE_CLUSTER_PATH" \
        --schema-dir "$EDGE_BROKEN_CRD_DIR"
    assert_exit_code 2 "a warm cache fails identically (the failure is not cached)"
    assert_stderr_contains "could not decode a document in " "the warm run reports it again"
    rm -rf "$xdg"
}

# ─── Registration ────────────────────────────────────────────────────────

test_case "validate_edge_sparse_files"           test_validate_edge_sparse_files
test_case "validate_edge_multidoc"               test_validate_edge_multidoc_all_docs_validated
test_case "validate_edge_crd_without_schema"     test_validate_edge_crd_without_schema_skips_kind
test_case "validate_edge_broken_yaml_fails"      test_validate_edge_broken_yaml_fails
test_case "validate_edge_missing_path_fails"     test_validate_edge_missing_path_fails
test_case "validate_edge_duplicate_keys"         test_validate_edge_duplicate_keys_fail_build
test_case "validate_edge_multiversion_crd"       test_validate_edge_multiversion_crd_per_version_schemas
test_case "validate_edge_broken_schema_file"     test_validate_edge_broken_schema_file_errors
test_case "validate_edge_no_resources"         test_validate_edge_no_resources
test_case "validate_edge_broken_crd_yaml"      test_validate_edge_broken_crd_yaml_fails
