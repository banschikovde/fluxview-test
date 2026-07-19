# fluxview smoke tests

End-to-end smoke tests for the [`fluxview`](https://github.com/banschikovde/fluxview)
CLI. Each scenario invokes the `fluxview` binary against fixture GitOps data
under `k8s/` and asserts on exit codes and stdout/stderr content.

## Layout

```
fluxview-test/
├── bin/fluxview              # built binary (gitignored)
├── crds/                     # CRD schemas for `validate` (JSON + YAML CRD)
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
| `test_build_ks.sh`    | `build ks` default, filters, aliases, errors | 20 |
| `test_build_hr.sh`    | `build hr` inflation, unsupported skip, dedup | 17 |
| `test_diff_ks.sh`     | `diff ks` changes detected, filters, colors | 16 |
| `test_diff_hr.sh`     | `diff hr` per-HR diffs, no-change path | 11 |
| `test_validate.sh`    | `validate` happy/invalid/missing schema | 14 |
| **Total**             |                                    | **235** |

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

The repo has two commits on `main`:

1. `Base smoke test data covering build/diff/validate scenarios`
   — the baseline state of all fixtures.
2. `Modify resources for diff tests`
   — three deliberate edits so `diff --branch-orig HEAD~1` finds changes:
   - `apps/podinfo/configmap-values.yaml` — `ui.color` and `ui.message` changed
   - `infra/deployment.yaml` — `replicas: 1 → 3`
   - `apps/backend/helmrelease.yaml` — `replicaCount: 2 → 5`, `nginx: 1.25 → 1.27`

`fake-podinfo/` is intentional: it duplicates the podinfo HelmRelease
(`namespace/name`) to exercise the dedup logic in `buildHRInflation`.

## Known fluxview issues surfaced by these tests

The smoke tests pass, but they also document two real fluxview bugs (each is
covered by a non-failing "known issue" test so regressions surface if the
behavior changes):

### 1. `validate` with a relative `--path` emits spurious warnings

```
$ fluxview validate --path k8s/test/cluster/
…
Warning: could not read k8s/test/cluster/apps.yaml: Rel: can't make
k8s/test/cluster/apps.yaml relative to /Users/…/fluxview-test
… (one per YAML file under --path)
```

The validation result and exit code are correct, but every YAML file under
the relative `--path` triggers a warning.

**Root cause:** `internal/cli/validate.go` computes `absClusterPath` (used
for the `os.Stat` check) but then passes the raw `clusterPath` (still
relative) into `flux.NewParser` and downstream walkers. The loose-file
reader in `buildKustomizeOverlays` calls `filepath.Rel(repoRoot, absPath)`
which fails because `absPath` isn't actually absolute.

**Fix:** pass `absClusterPath` consistently (as `build.go` already does).

**Test:** `test_validate.sh::validate_known_relative_path_warn`.

### 2. `diff hr --namespace <ns>` drops resources from charts that omit `{{ .Release.Namespace }}`

```
$ fluxview diff hr --path k8s/test/cluster/ --branch-orig HEAD~1 --namespace backend
…
Inflating HelmRelease backend/backend
No resources found in namespace "backend"
```

The `backend` HelmRelease is correctly inflated, but the resulting
`Deployment` has no `metadata.namespace` (the local chart doesn't template
`{{ .Release.Namespace }}`), so `filterByNamespace` in `computeAndOutputDiff`
filters it out. Charts that DO set namespace (e.g. the upstream `podinfo`
chart) work fine.

**Root cause:** `build hr` applies the namespace filter at the HelmRelease
level (inflate only matching HRs), but `diff hr` additionally applies a
resource-level filter at diff time. Helm rendering doesn't inject
`metadata.namespace` unless the chart sets it, so the resource-level filter
becomes a no-op for charts that don't.

**Fix options:**
- Inject `metadata.namespace` during inflation (set `helm template --namespace=<hr-ns>`),
  or
- Drop the resource-level filter from `computeAndOutputDiff` when the
  namespace was already applied at HR-inflation time.

**Test:** `test_diff_hr.sh::diff_hr_namespace_filter_known_gap`.
