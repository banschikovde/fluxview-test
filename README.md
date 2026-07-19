# fluxview-test

Smoke-test harness and GitOps fixtures for the
[`fluxview`](https://github.com/banschikovde/fluxview) CLI.

The repo serves two purposes:

1. **Fixture data** under `k8s/` — a minimal Flux GitOps layout exercising
   every fluxview feature (Kustomizations with dependencies, HelmReleases
   via OCIRepository / local GitRepository chart / Bucket / chartRef /
   suspended, custom CRDs, postBuild substitution, duplicates for dedup
   testing).
2. **Bash scenarios** under `tests/` — invoke the `fluxview` binary against
   those fixtures and assert on exit codes and output.

## Quick start

```bash
# 1. Build the fluxview binary from source (sibling checkout):
(cd ../flux-diff && go build -o ../fluxview-test/bin/fluxview ./cmd/fluxview/)

# 2. Run all smoke tests:
./tests/run_all.sh
```

See [`tests/README.md`](tests/README.md) for the full scenario list, the
git-history layout used for diff tests, and the two fluxview issues the
tests surfaced.

## Layout

```
k8s/
├── test/cluster/    # path passed to --path (Flux Kustomization CRs)
├── test/apps/       # HelmRelease scenarios
├── test/crds/       # CRD resources (the `crds` KS target)
├── test/infra/      # plain resources + custom Widget
└── invalid/         # schema-violating fixture for validate exit-code 3
crds/                # CRD schemas consumed by `validate`
tests/               # bash framework + scenarios
```
