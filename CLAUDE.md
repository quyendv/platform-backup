# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Four backup images (PostgreSQL, MongoDB, etcd, Vault) built from one shared bash
implementation. There is no application code: `lib/` is the whole program, and
each `backends/<name>/backend.sh` is a thin adapter.

## Commands

```bash
mise install                # pinned shellcheck, shfmt, hadolint, actionlint, bats
mise run check              # fmt:check + all linters + unit tests — exactly what CI runs
mise run fmt                # shfmt -w
mise run test:unit          # bats only
mise run build              # docker buildx bake --load, host arch
mise run test:integration   # real MinIO + Postgres + Mongo, backup→restore→verify

# One bats file, or one test
mise exec -- bats test/unit/retention.bats
mise exec -- bats --filter "KEEP=0" test/unit
```

Never invoke the tools directly — `mise exec --` (or a `mise run` task) is what
guarantees the pinned versions CI uses.

## Architecture

`lib/main.sh` owns the entire flow for every backend:

```
validate env → flock → backend_dump → checksum → upload → prune local → prune remote
```

An adapter implements only:

```bash
backend_name          # "postgresql"
backend_caps          # "fetch restore", or just "fetch" for etcd
backend_validate      # require_env for its own variables
backend_dump  <dir>   # write the artifact, echo its filename
backend_restore <path>
backend_restore_hint  # optional; printed when restore is unsupported
```

Adding a backend means one `backend.sh`, one Dockerfile, one `.env.example`,
k8s manifests, a bake target and a docs page — and no change to `lib/`.

In the image everything lands at `/opt/platform-backup/{entrypoint.sh,lib/,backend.sh}`,
so the build context is always the repo root and Dockerfiles are referenced by path.

## Invariants

These are load-bearing. Breaking one is a data-loss bug, not a style regression.

- **Logs go to stderr.** `backend_dump` and `_fetch_into` return values through
  stdout via command substitution. A log line on stdout silently corrupts them.
  This also applies to any `aws` call inside those helpers — `s3_upload_run`,
  `s3_download_run` and `s3_delete_run` redirect the CLI's own chatter to stderr.
- **`KEEP=0` disables pruning.** It must never be read as "keep zero backups".
- **Only `YYYYMMDD_HHMMSS` names are prune candidates.** Anything else living
  under the prefix belongs to someone else.
- **Prune deletes whole run folders**, never individual objects, so an artifact
  and its `.sha256` cannot be separated.
- **An empty listing is success.** Everything runs under `set -euo pipefail`,
  where a bare `grep` with no match aborts the job right after a successful
  upload. `prune_select` guards this.
- **Local and S3 share one layout** (`<run>/<artifact>`). That is what lets a
  single `prune_select` serve both sides; keep them symmetrical.
- **Timestamps are UTC.**

## Environment contract

Two prefixes, deliberately distinct:

- `AWS_*` — read by the AWS CLI itself. Never translate or rewrite these; that
  is what lets IRSA and instance roles work when they are unset.
- `S3_*` — read by this image (`S3_BUCKET`, `S3_PREFIX` only).

There is no addressing-style setting, and no `AWS_S3_ADDRESSING_STYLE` variable
exists in the AWS CLI — verified, not assumed. With a custom endpoint the CLI
already defaults to path-style; without one, virtual-hosted. Only
`s3.addressing_style` in `~/.aws/config` can change it.

Adding or renaming a variable means touching all of: the adapter or `lib/`, the
backend's `.env.example`, its `k8s/*.yaml`, its `docs/backends/*.md`, and the
table in `README.md`.

## Testing

TDD, with bats. Two rules that came from real misses in this repo:

1. **Test setups must `set -euo pipefail`.** Production sources `lib/` from
   scripts that do. Without it, a pipeline failure — `grep` with no match — is
   invisible in tests and fatal in production.
2. **A test asserting "nothing happened" passes when the function does not
   exist.** Assert `status -eq 0` as well, or the test can never go red. Same
   for `run find …` on a missing directory: bats folds stderr into `$output`,
   so the error message counts as one line.

Unit tests stub `aws` (see `test/unit/helpers/stub_aws.bash`), which verifies
the command that gets built but not that it is *valid* — a stub happily accepted
`aws s3 ls --delimiter`, which the real CLI rejects. Anything touching the AWS
CLI's actual surface needs `mise run test:integration`.

## CI

`ci.yml` runs `mise run check`, then builds only the backends a change touches
(amd64, no push on PRs). A change under `lib/`, `entrypoint.sh` or
`docker-bake.hcl` rebuilds all four.

`release.yml` fires on a per-backend tag (`postgresql/v1.2.0`) and is the only
place arm64 is *published* — emulated arm64 is slow and the postgres matrix
multiplies it by four.

Because nothing builds arm64 per-commit, it can rot silently. `mise run
verify:arm` (or the manual `arm64` workflow) builds it and runs the tooling
under emulation; do that before tagging, or after touching a Dockerfile.
Building alone proves nothing — layers assemble for any architecture, so
`test/smoke.sh` executes the actual binaries.

## History

This replaces four separate repositories (`quyendv/{postgresql,mongodb,etcd,vault}-backup`),
merged without their git history. `docs/superpowers/specs/2026-09-10-platform-backup-monorepo-design.md`
records what was inconsistent between them and why each decision went the way it
did; read it before revisiting a decision that looks arbitrary.
