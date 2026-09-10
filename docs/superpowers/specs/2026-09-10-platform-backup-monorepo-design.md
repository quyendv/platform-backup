# platform-backup monorepo — design

Date: 2026-09-10
Status: approved for planning

## Problem

Four backup images (`postgresql-backup`, `mongodb-backup`, `etcd-backup`, `vault-backup`)
live in four independent repositories. They solve the same problem with the same
shape — dump, compress, upload to S3, prune — but every repo drifted:

- **Retention**: `TTL_DAYS` + `MIN_BACKUPS` (pg/mongo), `RETENTION_DAYS` xor `KEEP_LAST`
  (etcd), `RETENTION_LOCAL_DAYS` + `RETENTION_S3_DAYS` with no count floor (vault).
  `MIN_BACKUPS` is a floor; `KEEP_LAST` disables age entirely. Same idea, three semantics.
- **S3 prefix**: `S3_PATH` (pg/mongo/etcd) vs `S3_PREFIX` (vault); defaults `backups`,
  `etcd`, `vault-snapshots`.
- **Artifact naming**: fixed names (pg/mongo) vs timestamped names (etcd/vault),
  forcing two different restore code paths.
- **`MODE=restore`** means three different things: real restore (pg/mongo),
  download-only (etcd), not implemented in the image at all (vault).
- **Local layout**: a per-run subdirectory (pg) vs flat files (mongo/etcd/vault).
- **Timestamps**: container-local time (pg/mongo) vs UTC (etcd/vault).
- **Credentials**: `aws configure set` + per-command `--endpoint-url` (pg/mongo) vs
  exporting `AWS_*` (etcd/vault).
- **supercronic**: unpinned `latest` (pg), `0.2.29` (mongo/etcd), `0.2.34` (vault);
  three different crontab paths; `-passthrough-logs` only on vault.
- **Logging**: coloured `log_info/log_success` (pg/mongo) vs timestamped `log/die`
  (etcd/vault); vault also writes a `LOG_FILE`.
- **Missing pieces**: only etcd takes a `flock`; only etcd/vault write `.sha256`;
  only vault has `--dry-run`; vault has no `k8s/restore-job.yaml`; no repo runs
  shellcheck (vault has it commented out); pg/mongo READMEs link to
  `scripts/demo-restore*.yaml`, which do not exist.

Fixing this in four places does not hold — the drift returns.

## Goals

1. One repository, one shared implementation, four thin backend adapters.
2. One env contract, one artifact layout, one retention model across all backends.
3. Lint and format enforced, runnable identically on a laptop and in CI.
4. Four independent images, each carrying only its own tooling.

## Non-goals

- Backward compatibility with the current env names. This is v2 on a new registry
  path; the old repositories keep working because they stop receiving updates.
- Preserving git history from the four repositories (they remain on GitHub).
- A single fat image containing every backend's CLI.

## Decisions

| Decision | Choice |
|---|---|
| Packaging | Four images, shared bash library |
| Compatibility | Clean break, no env aliases |
| Retention | Count-only (`KEEP_LOCAL`, `KEEP_REMOTE`), no age-based pruning |
| Restore | Three modes: `backup` / `fetch` / `restore` |
| Registry | `ghcr.io/quyendv/platform-backup/<backend>` |
| Git history | Fresh `git init`, no subtree merge |
| Visibility | Public repository |
| S3 env naming | `AWS_*` where the AWS CLI reads it natively; `S3_*` for what this image owns |
| Tooling | mise for tool pinning and task running |

## Architecture

### Repository layout

```
platform-backup/
├── mise.toml                  # tool versions + task runner
├── docker-bake.hcl            # build matrix, shared by local and CI
├── compose.yaml               # one service per backend, via profiles
├── .pre-commit-config.yaml
├── .editorconfig
├── .gitattributes             # LF for *.sh
├── entrypoint.sh              # shared by all four images
├── lib/                       # shared bash, COPY'd into every image
│   ├── log.sh
│   ├── env.sh
│   ├── s3.sh
│   ├── retention.sh
│   ├── checksum.sh
│   └── main.sh
├── backends/
│   ├── postgresql/{Dockerfile,backend.sh,.env.example,k8s/}
│   ├── mongodb/{Dockerfile,backend.sh,.env.example,k8s/}
│   ├── etcd/{Dockerfile,backend.sh,.env.example,k8s/}
│   └── vault/{Dockerfile,backend.sh,policies/,.env.example,k8s/}
├── test/integration/
└── docs/
```

Build context is the repository root; each Dockerfile is referenced by path so it
can `COPY lib/ entrypoint.sh`.

### Backend adapter contract

`lib/main.sh` owns the whole flow. Each `backends/<b>/backend.sh` implements five
hooks and nothing else:

```bash
backend_name        # echo "postgresql"
backend_caps        # echo "fetch restore"   (etcd: "fetch")
backend_validate    # die on missing/invalid backend-specific env
backend_dump  <dir> # write the artifact into <dir>, echo its filename
backend_restore <path>   # restore from the artifact; omitted when unsupported
backend_restore_hint     # optional; printed when restore is unsupported
```

`lib/main.sh` gates on `backend_caps`. When `MODE=restore` reaches a backend that
does not advertise it, the driver refuses and calls `backend_restore_hint` if the
adapter defines one — that is how etcd prints its host-side `etcdctl snapshot
restore` command without the driver knowing anything about etcd.

The driver runs:

```
resolve mode → validate env → flock → dump → checksum → upload
             → prune local → prune remote
```

`flock` (currently only in etcd) applies to all four. `DRY_RUN=true` (currently only
vault, as a CLI flag) short-circuits every mutating step for all four.

### Mode contract

| Mode | Meaning | postgresql | mongodb | vault | etcd |
|---|---|---|---|---|---|
| `backup` | dump and upload | yes | yes | yes | yes |
| `fetch` | download artifact to `RESTORE_DIR`, touch nothing else | yes | yes | yes | yes |
| `restore` | restore into the live target | yes | yes | yes | **no** |

`MODE=restore` against etcd exits non-zero and prints the `etcdctl snapshot restore`
command to run on the control-plane host with etcd stopped. A single meaning per
mode is the point: today `restore` silently means "download" on etcd.

`MODE=restore` ignores `SCHEDULE`, as it does today.

### Artifact layout

Local and remote share one shape, so a single `prune_keep` implementation serves both:

```
${BACKUP_DIR}/<ts>/<artifact>
s3://${S3_BUCKET}/${S3_PREFIX}/<ts>/<artifact>
```

`<ts>` is `YYYYMMDD_HHMMSS` in **UTC** for every backend (pg/mongo currently use
container-local time). Artifacts embed the timestamp and always ship a `.sha256`:

| Backend | Artifact |
|---|---|
| postgresql | `postgresql-<ts>.dump.gz` |
| mongodb | `mongodb-<ts>.archive.gz` |
| etcd | `etcd-<ts>.db` |
| vault | `vault-<ts>.snap.gz` |

Restore resolves `<ts>` first (newest run folder, or `RESTORE_TIMESTAMP`), then
derives the artifact name — no second listing call.

### Retention

Count-only. Sort run folders by timestamp descending, keep the first N, delete the
rest, on both sides independently:

- `KEEP_LOCAL` (default `3`) — run folders kept under `BACKUP_DIR`
- `KEEP_REMOTE` (default `30`) — run folders kept under `S3_PREFIX`
- `0` disables pruning on that side

Removed entirely: `TTL_DAYS`, `MIN_BACKUPS`, `KEEP_LAST`, `RETENTION_DAYS`,
`RETENTION_LOCAL_DAYS`, `RETENTION_S3_DAYS`.

Known trade-off: shortening `SCHEDULE` shortens the retention window without
warning. Accepted — predictable storage cost and immunity to a run of failed
backups matter more here, and the README states it.

Only whole run folders are deleted, never individual files, so an artifact and its
checksum can never be separated.

### S3 configuration

Verified against `aws-cli 2.36.42`:

| Mechanism | Result |
|---|---|
| `AWS_ENDPOINT_URL` | works |
| `AWS_ENDPOINT_URL_S3` | works, takes precedence |
| `AWS_S3_ADDRESSING_STYLE` (env) | **does not exist**, silently ignored |
| `s3.addressing_style` in `~/.aws/config` | works, both directions |
| default with a custom endpoint | path-style (`endpoint/bucket`) |
| default without an endpoint | virtual-hosted (`bucket.s3.region.amazonaws.com`) |

Two consequences.

First, **no addressing-style setting is exposed at all**. The CLI's defaults are
already right for every provider these images target: MinIO, Ceph RGW, R2, OVH and
DigitalOcean Spaces are all reached through a custom endpoint and therefore get
path-style, while real AWS gets virtual-hosted. A boolean `FORCE_PATH_STYLE` would
be a no-op in exactly the common case, and the opposite override is hypothetical.
If a provider ever needs it, mounting an `~/.aws/config` with `s3.addressing_style`
works without any image change, and an env can be added then.

Second, since no environment variable can carry addressing style, any future
support for it must write the config file — worth recording so nobody tries to
export `AWS_S3_ADDRESSING_STYLE` and wonders why it is ignored.

Credentials, region and endpoint therefore use the standard `AWS_*` variables
directly, with no translation layer:

```
AWS_ACCESS_KEY_ID  AWS_SECRET_ACCESS_KEY  AWS_SESSION_TOKEN
AWS_REGION         AWS_ENDPOINT_URL_S3
```

This deletes etcd's manual `S3_* → AWS_*` mapping and pg/mongo's `aws configure set`
plus per-command `--endpoint-url`. It also makes IRSA and EC2 instance roles work:
pg/mongo currently list `S3_ACCESS_KEY` in `REQUIRED_VARS`, which makes role-based
auth impossible.

Bucket and prefix have no standard AWS variable, so they stay `S3_`-prefixed. The
differing prefix is the signal: `AWS_*` is read by the AWS CLI itself, `S3_*` is
read by this image. Naming them `AWS_S3_BUCKET` would make them look native and
send anyone debugging a misconfiguration to the wrong place.

| Read by | Variables |
|---|---|
| AWS CLI, natively | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_REGION`, `AWS_ENDPOINT_URL_S3` |
| This image | `S3_BUCKET`, `S3_PREFIX` |

### Environment contract

Shared by all backends:

| Env | Default | Notes |
|---|---|---|
| `MODE` | `backup` | `backup` / `fetch` / `restore` |
| `SCHEDULE` | *(empty)* | empty = run once and exit |
| `BACKUP_DIR` | `/backup` | |
| `KEEP_LOCAL` | `3` | 0 disables |
| `KEEP_REMOTE` | `30` | 0 disables |
| `S3_BUCKET` | *(empty)* | empty = local-only |
| `S3_PREFIX` | `backups/<backend>` | |
| `RESTORE_TIMESTAMP` | *(latest)* | |
| `RESTORE_DIR` | `/restore` | |
| `DRY_RUN` | `false` | |

Backend-specific:

- **postgresql** — `POSTGRES_HOST/PORT/USER/PASSWORD/DB`, `POSTGRES_MAINTENANCE_DB`,
  `RESTORE_CLEAN`, and `RESTORE_DROP` (renamed from `RESTORE_DROP_DB`)
- **mongodb** — `MONGODB_URI`, `RESTORE_DROP`
- **etcd** — `ETCD_MODE`, `ETCD_ENV_FILE`, `ETCDCTL_*`
- **vault** — `VAULT_ADDR`, `VAULT_TOKEN`, `VAULT_TOKEN_FILE`

Also removed: `S3_UPLOAD` (inferred from `S3_BUCKET`), `WRITE_CHECKSUM` (always on),
`LOG_FILE` (stdout only — the container runtime owns log collection).

`RESTORE_DROP` covers both `DROP DATABASE` (postgresql) and
`mongorestore --drop` (mongodb): same intent, one name.

### Logging

One style everywhere: `lib/log.sh` with `log_info/log_warn/log_error/die`, timestamped,
to stdout/stderr, colour only when the stream is a TTY (cron output in a k8s log is
not improved by ANSI escapes).

### Images

| Backend | Base | Platforms |
|---|---|---|
| postgresql | `debian:bookworm-slim` + pgdg client, `PG_VERSION` 14–17 | amd64, arm64 |
| mongodb | `debian:bookworm-slim` + mongodb-database-tools | amd64, arm64 |
| etcd | `alpine` + etcdctl | amd64, arm64 |
| vault | `hashicorp/vault` | amd64, arm64 |

All four images are multi-arch. Vault is amd64-only today not because of its base
image — `hashicorp/vault:1.18` publishes an arm64 manifest — but because its
Dockerfile hardcodes the `supercronic-linux-amd64` download URL. Selecting the
binary by `TARGETARCH` removes the limitation.

supercronic is pinned once, in a single build arg shared by all four Dockerfiles.
The `CMD []` in the vault Dockerfile stays — it clears the base image's CMD, which
would otherwise arrive as arguments to the entrypoint.

Tags:

```
ghcr.io/quyendv/platform-backup/postgresql:{pg14,pg15,pg16,pg17,latest}   # latest = pg17
ghcr.io/quyendv/platform-backup/mongodb:latest
ghcr.io/quyendv/platform-backup/etcd:latest
ghcr.io/quyendv/platform-backup/vault:latest
```

A release tag adds its semver alongside these (`postgresql:1.0.0-pg17`,
`mongodb:1.0.0`).

`docker-bake.hcl` defines the build matrix once and is used by both `mise run build`
and CI, so local and CI builds cannot diverge.

## Tooling

`mise.toml` pins the tools and defines the tasks:

| Task | Does |
|---|---|
| `fmt` | `shfmt -w` over `lib/`, `backends/`, `entrypoint.sh`, `test/` |
| `fmt:check` | `shfmt -d` (non-zero on diff) |
| `lint:sh` | `shellcheck -x` |
| `lint:docker` | `hadolint` on every Dockerfile |
| `lint:ci` | `actionlint` on the workflows |
| `lint` | the three above |
| `check` | `fmt:check` + `lint` |
| `build` | `docker buildx bake` |
| `test` | integration suite |

`.pre-commit-config.yaml` runs `mise run fmt`, `mise run lint:sh` and `gitleaks`, so
formatting failures are caught before a push rather than by a CI round-trip.

CI runs `mise run check` — the same command, so "passes locally, fails in CI" cannot
happen through tool version skew.

## CI/CD

Two workflows, tiered by event. The repository is public, so Actions minutes are
unlimited; the tiering exists because QEMU-emulated arm64 builds are slow, and the
postgresql matrix multiplies that by four.

| Event | Jobs |
|---|---|
| pull request | `mise run check`; build amd64 for changed backends only, no push |
| push to `main` | `mise run check`; build and push amd64 for changed backends |
| tag `<backend>/v*` | full matrix including arm64, build and push |

Path filters: a change under `lib/`, `entrypoint.sh` or the bake file rebuilds all
four; a change under `backends/<b>/` rebuilds only that backend.

Tags are per-backend (`postgresql/v1.0.0`), so backends release independently.

## Testing

- **Static**: shellcheck, shfmt, hadolint, actionlint on every PR. No repository has
  this today.
- **Integration**: `test/integration/` brings up MinIO plus a real target with docker
  compose, then runs `backup → fetch → restore → verify` and asserts on the restored
  data. Covers postgresql, mongodb and vault (dev server) in CI.
- **etcd**: manual, documented. It needs a real etcd with TLS or a host systemd unit,
  and its restore path runs outside the container by design.
- **Unit**: bats-core, pinned through mise like every other tool, covering the pure
  functions in `lib/` — retention selection, prefix normalisation, env parsing.
- **Retention**: bats tests for `prune_keep` against a fake listing —
  boundary cases `KEEP=0`, `KEEP` greater than the number of runs, and malformed
  folder names that must be ignored rather than deleted.

## Migration

1. Confirm all four working trees are clean and pushed (`git status`, compare against
   `origin/<default branch>`). Stop and report if anything is unpushed.
2. Get explicit confirmation, then remove the four `.git` directories.
3. `git init` at the workspace root; add `.gitattributes` and `.gitignore` first.
4. Move files into the new layout; extract `lib/`; rewrite each backend as an adapter.
5. Add mise, bake, compose, pre-commit, workflows.
6. Rewrite the documentation: one root README, one page per backend, and a table
   mapping every removed env to its replacement.
7. First commit, push to `github.com/quyendv/platform-backup`.
8. Tag each backend once the integration suite passes.

The four old repositories stay untouched on GitHub as the historical record.

## Risks

| Risk | Mitigation |
|---|---|
| Deleting `.git` loses local-only work | Verify pushed state and get confirmation before deleting |
| Count-only retention shortens the window when `SCHEDULE` changes | Documented; `KEEP_REMOTE` default 30 |
| Shared `lib/` means one bug reaches all four images | Integration suite covers three backends; `lib/` changes rebuild everything |
| Restore paths are the least-tested and most destructive | `fetch` separated from `restore`; `DRY_RUN` on all backends; etcd refuses to restore in-container |
| New image path means existing deployments do not auto-upgrade | Intended — old repos are frozen, new registry path is a deliberate cut |
