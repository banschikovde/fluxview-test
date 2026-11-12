# fluxview smoke tests

End-to-end smoke tests for the [`fluxview`](https://github.com/banschikovde/fluxview)
CLI. Each scenario invokes the `fluxview` binary against fixture GitOps data
under `k8s/` and asserts on exit codes and stdout/stderr content.

## Layout

```
fluxview-test/
├── bin/fluxview              # built binary (gitignored)
├── schemas/                 # validation schemas for `validate` (JSON + YAML CRD + checkout)
├── k8s/
│   ├── test/                 # main cluster fixture
│   │   ├── cluster/          # Flux Kustomization CRs (used as --path)
│   │   ├── apps/             # HelmRelease scenarios
│   │   │   ├── podinfo/      # OCIRepository chart source (works)
│   │   │   ├── fake-podinfo/ # duplicate HelmRelease (dedup test)
│   │   │   ├── backend/      # local Helm chart via GitRepository source
│   │   │   ├── bucket-app/   # Bucket source (must be skipped)
│   │   │   ├── helmchart-hr/ # chartRef kind: HelmChart (must be skipped)
│   │   │   └── suspended-hr/ # suspended HelmRelease (must be skipped)
│   │   ├── crds/             # CRD resources (resolves the `crds` KS)
│   │   └── infra/            # plain resources (namespace filter, custom CRD)
│   └── invalid/              # fixture with schema violations for validate
└── tests/
    ├── run_all.sh            # entry point
    ├── lib/framework.sh      # assertions: assert_exit_code, assert_contains, …
    └── test_*.sh             # one file per command
```

## Build the binary

```bash
# From the fluxview source tree (../flux-diff):
go build -o ../fluxview-test/bin/fluxview ./cmd/fluxview/
```

Or point the runner at an existing binary:

```bash
FLUXVIEW_BIN=/usr/local/bin/fluxview tests/run_all.sh
```

## Run

```bash
# All tests:
tests/run_all.sh

# A single file:
tests/run_all.sh tests/test_build_ks.sh

# Multiple files:
tests/run_all.sh tests/test_build_ks.sh tests/test_diff_ks.sh

# Compare against a specific base revision (default: HEAD~1):
DIFF_BASE_REV=main~2 tests/run_all.sh tests/test_diff_ks.sh
```

Exit codes:
- `0` — all tests passed
- `1` — one or more tests failed; details printed and in `tests/.results/_failures.txt`
- `2` — preflight error (no binary, no test files)

Per-test stdout/stderr is captured under `tests/.results/<test>.stdout` and
`.stderr` for post-mortem inspection.

## Coverage

| File                  | Command                            | Tests |
|-----------------------|------------------------------------|-------|
| `test_root.sh`        | help, version, exit codes, unknown args/flags | 13 |
| `test_build_ks.sh`    | `build ks` default, filters, aliases, errors | 21 |
| `test_build_hr.sh`    | `build hr` inflation, unsupported skip, dedup, `--kubernetes-version`/`FLUXVIEW_KUBE_VERSION` (kubeVersion-capped charts: upper-bound default render, override, env, invalid rejected) | 22 |
| `test_diff_ks.sh`     | `diff ks` changes detected, filters, colors | 16 |
| `test_diff_hr.sh`     | `diff hr` per-HR diffs, no-change path, `--kubernetes-version` (kubeVersion-capped chart diffs instead of exit 2, strict failure at the assumed default, override) | 13 |
| `test_external_sources.sh` | external `GitRepository` sources: file:// pinned tag / floating branch, `--git-source-cache-dir`/`-ttl`, SSH host key policies via a local sshd fixture, https credential host scoping (`FLUXVIEW_GIT_CREDENTIAL_HOSTS`) via a local 401 server | 10 |
| `test_validate.sh`    | `validate` kubeconform engine: native k8s via registry, CRD schemas, cache, version flag (+ `master`, short-form rejected, mass-skip warning), `--strict`, `--skip-kind`, `--schema-download-timeout` (0 ok / negative rejected), `--output json/junit` (incl. passing-run reports with skipped cases), `FLUXVIEW_KUBE_VERSION` env (schema version pinned, short form warns + falls back) | 34 |
| `test_validate_edge.sh` | `validate` edge cases: empty/`---`/comment-only files, multi-doc YAML, CRD without structural schema, broken YAML fails (exit 2), KS with missing spec.path fails (exit 2), duplicated YAML keys fail the build (exit 2), multi-version CRD (per-version schemas), corrupt JSON schema file (error, not skip), zero-resource build, broken CRD YAML (hard error exit 2, never cached) | 10 |
| `test_validate_kjs.sh` | `validate` kubernetes-json-schema checkout: local priority over registry, registry fallback, `v`-prefix requirement, `-standalone-strict` variant under `--strict` | 4 |
| `test_inventory.sh`   | `inventory` `--kubernetes-version` (kubeVersion-capped charts render, override, invalid rejected, flag registered) | 4 |
| **Total**             |                                    | **406 assertions** |

Row counts are registered test cases; the runner's Total counts individual
assertions (each case checks several properties), hence 147 rows against
406 assertions.

Each test exercises:
- **Happy path** — exit 0, expected output snippets.
- **Filters** — `--namespace` (long + `-n`), `--path` (long + `-p`), `--name`.
- **Flags** — `--skip-crds`, `--strip-attrs`, `--unified`, `--color`, `--schema-dir`.
- **Exit codes** — `0` success, `1` diff found, `2` error, `3` validation failed.
- **Error paths** — bad path, unknown resource type/name, missing args.
- **Help / version** — `--help`, `-h`, `--version`, `-v`.

Unsupported-but-graceful scenarios (HelmRelease with Bucket source,
`chartRef.kind: HelmChart`, suspended HelmRelease) are verified to print
warnings and continue.

## Test data and git history

The repo has the following commits on `main`:

1. `Base smoke test data covering build/diff/validate scenarios`
   — the baseline state of all fixtures (tagged **`smoke-base`**).
2. `Modify resources for diff tests`
   — three deliberate edits so `diff --branch-orig smoke-base` finds changes:
   - `apps/podinfo/configmap-values.yaml` — `ui.color` and `ui.message` changed
   - `infra/deployment.yaml` — `replicas: 1 → 3`
   - `apps/backend/helmrelease.yaml` — `replicaCount: 2 → 5`, `nginx: 1.25 → 1.27`
3. `Add fluxview smoke test framework` — this test harness.

The runner compares against the `smoke-base` tag by default (it falls back
to `HEAD~1` if the tag is missing). Override with the `DIFF_BASE_REV`
environment variable.

`fake-podinfo/` is intentional: it duplicates the podinfo HelmRelease
(`namespace/name`) to exercise the dedup logic in `buildHRInflation`.

## Previously known fluxview issues (fixed)

Two issues this suite used to document as open "known issues" are fixed in
the current fluxview binary and locked in as positive regression tests:

1. `validate` with a relative `--path` no longer emits `Rel: can't make …`
   warnings — `validate` now passes the absolute cluster path through, the
   same way `build` always did.
   Test: `test_validate.sh::validate_relative_path_no_warnings`.

2. `diff hr --namespace <ns>` no longer drops resources from charts that
   omit `{{ .Release.Namespace }}` — inflation injects the HelmRelease
   namespace into every rendered resource, so the resource-level filter
   matches.
   Test: `test_diff_hr.sh::diff_hr_namespace_filter`.

