# Changelog

Notable changes to platform-backup. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[semantic versioning](https://semver.org/).

While the major version is `0`, the environment contract may still change
between minor versions. Each change will be listed here with its migration.

## [Unreleased]

### Added

- **A secret scan that actually gates.** `mise run scan:secrets` runs gitleaks
  over the full history and is part of `check`, so CI enforces it. The
  pre-commit hook stays, but a hook lives in a clone: it is absent until
  someone installs it, and `--no-verify` skips it.
- **`mise run test:k8s`**, which proves the offline restore runbook on a kind
  cluster with the Bitnami chart and two replicas. It applies the manifest the
  repository ships rather than a copy, so the documented procedure cannot rot
  unnoticed.
- **`FETCH_DECOMPRESS`**, so `MODE=fetch` unpacks a `.gz` artifact ready to
  place in a server's data directory. That offline path — place the file,
  restart — is far cheaper than replaying into a live server where the artifact
  is the server's own state format: measured at 130 ms against 11 seconds for
  200k Redis keys, and half the memory. Documented for redis with a runbook for
  Docker and for the Bitnami chart with replicas, verified on a real cluster.
- **A Redis backend**, `ghcr.io/quyendv/platform-backup/redis`. RDB snapshots
  pulled over the network with `redis-cli --rdb`; restore stages the RDB on a
  throwaway `redis-server` inside the container and `MIGRATE`s the keys across,
  which preserves data types and TTLs. Tagged per major version (`redis7`,
  `redis8`, `latest` = `redis8`) because RDB is not backward compatible — Redis
  8 writes `REDIS0015`, which `redis-server` 7.4 will not load.

  Two things it refuses rather than half-doing:

  - **Redis Cluster.** A cluster shards its keyspace and `--rdb` returns only
    the node it is aimed at; `-c` does not change that. Three masters holding
    100 keys measured 33, 30 and 37, so one URL would back up a third of the
    data and report success. Back up each master separately for now.
  - **Restoring into a `rediss://` target.** `MIGRATE` runs on the staging
    server and has no TLS option. Backup over TLS works normally.

  Restore loads the whole dataset into the backup container's memory, so a
  10 GB Redis needs a 10 GB limit on the pod. Documented with the backend.

### Changed

- **Restore now documents that it assumes no traffic.** None of these restores
  are atomic, so writes arriving while one runs interleave with the restored
  data and nothing afterwards distinguishes them. Previously implied, now
  stated.
- **Kubernetes manifests use a single Secret**, not a Secret plus a ConfigMap.
  Splitting them only pays off where RBAC separates who may read configuration
  from who may read credentials, or where an external secret manager owns the
  Secret; otherwise it is a second object to keep in sync, and it puts the
  bucket and endpoint somewhere usually readable by more principals.
- **Notifications are configured in the manifests**, with `NOTIFY_ON=failure`
  and every channel listed commented out. A CronJob gives each run a fresh
  pod, so the state file never survives and "previous outcome" is always
  unknown: failures notify as normal, `change` would fire on every run, and a
  recovery message can only be sent if `/backup` is a PersistentVolumeClaim.
  That is now written down next to the setting.
- Restore and fetch Jobs set `NOTIFY_ON=never`: a restore is deliberate and
  watched, so announcing it is noise.

### Added

- A test that every variable named in a manifest or an example is one the
  image actually reads. A typo passes YAML validation and a dry run, then
  silently does nothing.


## [0.2.0] — 2026-09-12

Backups now say when they fail. Everything here is additive: no environment
variable changed meaning, and 0.1.0 backups restore unchanged.

### Added

- **A state file.** Every run writes `${BACKUP_DIR}/.last-run.json` with its
  outcome, backend, run id, error, exit code and duration.
- **A container healthcheck.** A scheduled container whose backups fail used
  to stay `Up` with exit code 0, the only evidence a line in the log. It now
  reports `unhealthy`, which `docker ps`, restart policies and anything
  watching container health can see. `HEALTHCHECK_MAX_AGE` additionally
  catches a schedule that quietly stopped firing.
- **Notifications** to Slack, Google Chat, Discord, Telegram, a structured
  webhook and email over SMTP — any number at once, each enabled by its own
  variables. The message leads with a status icon and headline, then aligned
  fields (run, target, duration, exit, error), rendered per channel: HTML for
  Telegram, fenced markdown for the chat webhooks, plain text for email. `NOTIFY_ON` selects `never`, `change`, `failure` (default) or
  `always`; `failure` includes the first success after a failure, so you learn
  when the problem went away. A channel that fails is logged and skipped and
  never changes a run's outcome.

### Fixed

- **A failed run left no record.** `die` exits, so running the dispatch in the
  same shell unwound past the reporting entirely.
- **Fetch chose its artifact by directory order.** It took the first file
  that was not a `.sha256`, which is not deterministic — the same run folder
  selected a different file on a CI runner than it did locally. The checksum
  sidecar now identifies the artifact, which also makes it the marker of a
  complete run: half an upload is rejected up front instead of part-way
  through a restore.
- **A long error lost the notification.** Telegram rejects a message over
  4096 characters and Discord over 2000, so a verbose dump failure — the case
  that matters most — produced no message at all. The error is now capped at
  `NOTIFY_MAX_ERROR_CHARS` for chat; webhook and email keep it whole.
- **HTML escaping was broken by a bash 5.2 change.** An unescaped `&` in the
  replacement half of a parameter substitution now means "the text that
  matched", so escaping `<` produced `<lt;` rather than `&lt;`, and Telegram
  rejects a message whose entities it cannot parse. Escaping goes through sed.
- **Adapters could swallow a failed dump.** `backend_dump` ends by echoing the
  artifact filename, so the function's status reflected that echo rather than
  the dump, and errexit is disabled inside the tested context the driver calls
  it from. A failed `pg_dump` was reported three steps later as "artifact too
  small". Every adapter now checks its own tool.

### Changed

- Each backend's documentation moved from `docs/backends/<name>.md` to
  `backends/<name>/README.md`, beside the code it describes.
- The recorded error is the **first** one, not the last: the earliest is the
  cause, everything after it is the driver unwinding.
- `jq` is installed in all four images, for correct JSON in state, payloads
  and the healthcheck.


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

[Unreleased]: https://github.com/quyendv/platform-backup/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/quyendv/platform-backup/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/quyendv/platform-backup/releases/tag/v0.1.0
