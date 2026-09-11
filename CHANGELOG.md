# Changelog

Notable changes to platform-backup. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[semantic versioning](https://semver.org/).

While the major version is `0`, the environment contract may still change
between minor versions. Each change will be listed here with its migration.

## [Unreleased]

## [0.1.0] — 2026-09-11

First release of the consolidated repository. It replaces four separate
projects — `quyendv/postgresql-backup`, `mongodb-backup`, `etcd-backup` and
`vault-backup` — with one implementation behind four thin adapters.

Those repositories are frozen, not deleted. Their images keep working; they
simply stop receiving updates. **These images cannot restore a backup taken by
them** (see *Changed → Layout*), so keep the old image until the retention
window on existing backups has passed.

### Added

- **`MODE=fetch`.** Downloads a run into `RESTORE_DIR`, verifies its checksum
  and stops, touching neither the database nor the object store. Previously
  the only way to inspect a backup was to restore it.
- **Artifact integrity verification.** Every backend checks its own artifact
  before a run is promoted: `pg_restore --list` for postgresql, `gzip -t` for
  mongodb and vault, `etcdctl snapshot status` for etcd.
- **Checksums everywhere.** Every artifact ships a `.sha256` sidecar, and
  `fetch` and `restore` verify it before touching the data. Previously only
  etcd and vault wrote one.
- **`DRY_RUN`** on all four backends. Previously a `--dry-run` flag on vault
  alone.
- **Restore for vault.** `scripts/vault-restore.sh` existed in the old
  repository but was never copied into the image.
- **A single concurrency lock** on all four backends, so a schedule that fires
  faster than a dump completes cannot interleave two runs. Previously etcd
  only.
- **`MIN_ARTIFACT_BYTES`** (default `128`), a floor below which a dump is
  treated as failed.
- **Kubernetes manifests for every backend**, with configuration in a
  ConfigMap and only secrets in the Secret. vault had no restore Job at all.
- **Continuous integration.** shellcheck, shfmt, hadolint and actionlint on
  every pull request, 99 unit tests, and an integration suite that runs
  backup → fetch → restore against real MinIO, PostgreSQL, MongoDB and Vault.
  No predecessor repository ran a linter; one had shellcheck commented out.
- **`mise run verify:arm`** and a manual `arm64` workflow, so the architecture
  that is only published on release tags can still be checked before tagging.

### Changed

- **Environment contract.** Names are aligned across backends, with no
  aliases. Full mapping in [README](README.md#migrating-from-the-separate-repositories):

  | Old | New |
  |---|---|
  | `S3_ACCESS_KEY`, `S3_SECRET_KEY` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |
  | `S3_ENDPOINT` | `AWS_ENDPOINT_URL_S3` |
  | `S3_REGION` | `AWS_REGION` |
  | `S3_PATH` | `S3_PREFIX` |
  | `TTL_DAYS`, `RETENTION_DAYS`, `RETENTION_LOCAL_DAYS` | `KEEP_LOCAL` |
  | `RETENTION_S3_DAYS` | `KEEP_REMOTE` |
  | `MIN_BACKUPS`, `KEEP_LAST` | folded into `KEEP_LOCAL` / `KEEP_REMOTE` |
  | `RESTORE_DROP_DB` | `RESTORE_DROP` |
  | `--dry-run` argument | `DRY_RUN=true` |

  Credentials, region and endpoint now use the AWS CLI's own variables and are
  not rewritten, so leaving them unset falls through to an EC2 instance role
  or an EKS service account. The old images listed `S3_ACCESS_KEY` as
  required, which made role-based authentication impossible.

- **Retention is a count, not an age.** `KEEP_LOCAL` and `KEEP_REMOTE` keep the
  newest N runs on each side; `0` disables pruning there. This replaces four
  different age-based schemes whose semantics disagreed — `MIN_BACKUPS` was a
  floor added to an age limit, while `KEEP_LAST` disabled the age limit
  entirely. To preserve an existing window, multiply: `TTL_DAYS=7` on a
  four-hourly schedule was roughly 42 runs, so `KEEP_REMOTE=42`.

  Note this couples the window to `SCHEDULE`: moving from four-hourly to
  hourly shortens how far back 30 runs reach, from five days to just over one.

- **`MODE` has one meaning per value.** It previously meant a real restore on
  two images, a download on a third, and nothing at all on the fourth. `etcd`
  now refuses `MODE=restore` with an explanation and the `etcdctl` command to
  run on the host, instead of downloading a file and calling it a restore.

- **Layout.** Local and remote share one shape, `<run>/<artifact>`, with UTC
  timestamps everywhere (postgresql and mongodb used container-local time).
  Artifact names now carry their timestamp:

  | Backend | Old | New |
  |---|---|---|
  | postgresql | `postgresql_backup.dump.gz` | `postgresql-<ts>.dump.gz` |
  | mongodb | `mongodb_backup.archive.gz` | `mongodb-<ts>.archive.gz` |
  | etcd | `etcd-snapshot-<ts>.db` | `etcd-<ts>.db` |
  | vault | `vault-snapshot-<ts>.snap.gz` | `vault-<ts>.snap.gz` |

- **Images move to `ghcr.io/quyendv/platform-backup/<backend>`.** postgresql
  keeps its `pg14`–`pg17` tags, with `latest` now tracking pg17.
- **Logs go to stderr** and carry a UTC timestamp, in one format across all
  backends. Colour only when attached to a terminal.
- **vault runs as a non-root user** (uid 100, the base image's own) and is now
  published for arm64 as well as amd64.

### Fixed

Carried over from the predecessor repositories:

- **Scheduled mode never worked.** `exec supercronic` passed a bare name as
  `argv[0]`; as PID 1 supercronic re-execs `argv[0]` for process reaping, that
  exec failed with `ENOENT` and the container died before running a single
  backup. It is now invoked by absolute path.
- **A failed run could destroy good backups.** The run directory was created
  before the dump, so a failure left an empty timestamped directory behind.
  Because pruning keeps the newest N directories, a few failures in a row
  evicted every good backup before them — three good backups became one. Runs
  are now assembled in a staging directory and promoted only once complete.
- **`@every 6h` was documented but fatal.** supercronic documents the syntax;
  the build shipped in these images rejects it and exits. Examples now use
  `@hourly` and `@daily`.
- **Object store errors were reported as missing backups.** Listing discarded
  stderr, so a missing bucket, a denied policy or bad credentials all surfaced
  as "no backup runs found". An empty prefix and a failed listing are now told
  apart.
- **Pruning reported success for work it never did.** A listing failure inside
  a process substitution is invisible; the listing is now checked explicitly.
- **`aws s3 ls --delimiter`** was passed a flag the high-level `s3` command
  does not accept, so every restore failed to find its backup.
- **Two runs in the same second corrupted a run folder**, because `mv` nested
  the staging directory inside the existing one. Promotion now refuses.
- **The backup lock was never released**, so a second run in the same process
  was always refused.
- **`find | head -n1` under `pipefail`** returns 141 when `head` closes the
  pipe first — latent while run folders held two files.

### Removed

- `S3_UPLOAD` — an empty `S3_BUCKET` now means local-only.
- `WRITE_CHECKSUM` — checksums are always written.
- `LOG_FILE` — logs go to stderr; the container runtime owns collection.
- `TTL_DAYS`, `RETENTION_DAYS`, `RETENTION_LOCAL_DAYS`, `RETENTION_S3_DAYS`,
  `MIN_BACKUPS`, `KEEP_LAST`, `S3_PATH` — see *Changed*.
- The four per-repository workflows, replaced by one CI and one release
  workflow.

### Known limitations

- **etcd has no integration test.** It needs a real etcd with TLS on the host
  network, and its restore runs outside the container by design.
- **A failing scheduled backup is easy to miss.** The container stays up with
  exit code 0 and no healthcheck; the only evidence is a line in the log.
  Kubernetes CronJob users get this from Job status. Notifications and a
  healthcheck are the next piece of work.
- **arm64 is only built on release tags**, so it can break between releases.
  `mise run verify:arm` covers it in the meantime.

[Unreleased]: https://github.com/quyendv/platform-backup/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/quyendv/platform-backup/releases/tag/v0.1.0
