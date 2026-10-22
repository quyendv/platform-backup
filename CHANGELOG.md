# Changelog

Notable changes to platform-backup. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[semantic versioning](https://semver.org/).

While the major version is `0`, the environment contract may still change
between minor versions. Each change will be listed here with its migration.

## [Unreleased]

## [0.6.2] — 2026-10-22

Both found by the first restore drill against a real deployment. Backups
written by 0.6.x are fine; it is getting them back that failed.

### Fixed

- **Every download failed against some S3-compatible providers.** The images
  ship AWS CLI 2.38, whose default sends checksum headers on every request; one
  provider rejected each GetObject with "Value for x-amz-checksum-mode header is
  invalid". Uploads kept working, so backups looked healthy while `fetch`,
  `restore` and `VERIFY_READBACK` could not read a single object. The images
  now default `AWS_REQUEST_CHECKSUM_CALCULATION` and
  `AWS_RESPONSE_CHECKSUM_VALIDATION` to `when_required`; set either to override.
- **postgresql: `RESTORE_GLOBALS` locked the restore out of the server.** A
  superuser's globals carry its own `ALTER ROLE … PASSWORD`; applied first, it
  reset the password of the role the restore was connected as, and
  `pg_restore` then failed to log in. The connecting role's own `CREATE ROLE`
  and `ALTER ROLE` lines are now skipped; every other role and membership is
  applied.

## [0.6.1] — 2026-10-22

### Fixed

- **postgresql: verification failed for every dump larger than a pipe
  buffer.** `pg_restore --list` stops reading once it has the table of
  contents, so `gunzip` died of SIGPIPE and pipefail failed the run with
  "Artifact failed postgresql verification". Small databases passed, which is
  why the fixtures never caught it. The rest of the stream is now drained;
  `gzip -t` has already read every byte. The integration suite now backs up a
  database larger than a pipe buffer. Present since the postgresql backend
  first verified with `pg_restore --list`; 0.6.0 is the first release whose
  users hit it at scale.

## [0.6.0] — 2026-10-22

A run now counts only once it is wholly in the bucket, and two backends gain
what a restore to a fresh server needs. Upgrade in place: 0.5.x runs keep
working, and history is never pruned below `KEEP_REMOTE` real backups.

### Added

- **A `_COMPLETE` marker, uploaded last by every run.** It is JSON naming the
  run, backend, host, image version, the artifact and every file. `fetch` and
  `restore` pick the newest run that has one; `KEEP_REMOTE` counts only those.
  A run without a marker (an interrupted upload, or one written before 0.6.0)
  is deleted once `KEEP_REMOTE` complete runs are newer than it, can still be
  fetched by `RESTORE_TIMESTAMP`, and is used as the newest only where no run
  has a marker yet.
- **`VERIFY_READBACK`** (default `false`): after upload, stream every object
  back and compare its SHA-256 before writing the marker. One download per run.
- **`BACKUP_HOST`**: the name recorded in `.last-run.json` (new `host` field),
  in `_COMPLETE` and in notifications. Defaults to the container's hostname.
- **mongodb: `MONGODUMP_OPLOG=auto|true|false`** (default `auto`). On a
  replica set — `replicaSet=` in the URI, or `mongodb+srv://` — and with no
  database in the URI, the dump takes `--oplog` and is one point in time. Such
  an artifact is named `mongodb-<run>.oplog.archive.gz`, and restore replays it
  with `--oplogReplay`.
- **postgresql: `POSTGRES_DUMP_GLOBALS`** (default `true`) also writes
  `pg_dumpall --globals-only` to `globals-<run>.sql.gz`; without superuser
  rights it adds `--no-role-passwords`. **`RESTORE_GLOBALS=true`** applies it
  before the restore — for a fresh server, where roles and memberships are
  otherwise missing.
- `PLATFORM_BACKUP_VERSION` is baked into every image.

### Changed

- **Listing is recursive** (`aws s3 ls --recursive`), once per prune or
  resolve, so completeness costs no request per run.
- A backend may write companion files beside its artifact; each gets its own
  `.sha256`, and `fetch` verifies every sidecar in the run.
- Every manifest and compose file pins 0.6.0.

### Fixed

- **Notifications reported a duration of 0.** The duration was recorded in
  `.last-run.json` but never passed to the notifier.

## [0.5.1] — 2026-10-20

Every image gets one fix that matters: a backup whose upload failed was
reported as a success. Upgrade from any earlier version. Everything else here
is deployment files and documentation; 0.5.0 artifacts verify, fetch and
restore unchanged.

### Added

- **A Docker deployment for every backend**, `backends/<name>/docker/compose.yaml`,
  beside the Kubernetes one. Each pins a release tag, is its own Compose
  project, keeps `/backup` on a persistent volume so the `HEALTHCHECK` and
  `NOTIFY_ON=change` work, keeps the image's meaning of `SCHEDULE` (set: on
  that cron; empty: once) with `RESTART_POLICY` defaulting to `no` so a
  one-shot run is never restarted into a loop, and has a separate
  `restore` service so a manual fetch or restore never overwrites the
  scheduled job's state. The root `compose.yaml` stays as the development file
  that builds from source.
- **vault: tokens that keep working.** The Docker deployment runs Vault Agent
  as a sidecar, logging in with AppRole and writing the token to an in-memory
  volume; the Kubernetes CronJob runs it as an init container logging in with
  the pod's ServiceAccount (Kubernetes auth). The image reads
  `VAULT_TOKEN_FILE` at the start of every run, so it always uses the agent's
  current token.

### Changed

- **vault: the Kubernetes manifests no longer take a `VAULT_TOKEN`.** Migration:
  configure Kubernetes auth and the `vault-backup` role (backends/vault/README.md),
  then apply `k8s/cronjob.yaml`, which adds a ServiceAccount and a ConfigMap.
  `k8s/restore-job.yaml` reads its privileged token from a separate
  `vault-restore-token` Secret, created for the restore and deleted after it.
- **vault: the documentation stops recommending periodic tokens.** The image
  never renews a token, so `vault token create -period=…` expired one period
  after creation and every run after that failed with `403 invalid token`
  while the container stayed `Up`.
- **The README lists release tags** and says what the moving ones are.
- **Every Kubernetes manifest pins 0.5.1** (`0.5.1-pg17`, `0.5.1-redis8`), as
  do the new compose files. They pinned 0.2.0, or the moving `redis8` and
  `latest` tags.

### Fixed

- **A failed upload was reported as a successful backup.** With S3
  unreachable, a run logged `Uploaded run` and `complete`, recorded
  `outcome: success`, exited 0 and left the container `(healthy)`, so the
  only copy was the local one — an `emptyDir` on Kubernetes. The backup ran as
  `"$@" || rc=$?` inside the lock, which switches errexit off for everything
  it calls; any step that did not check its own status could not fail the run.
  It now runs under errexit, and the upload names itself when it fails. A
  failed remote prune fails the run too, as it was always meant to. Affects
  every backend and every version before this one.
- **A failure that logged no `[ERROR]` line was never recorded or notified.**
  Extracting the cause ran `grep | head` under pipefail; with no match it
  aborted the reporting itself. The cause now falls back to the exit status,
  as intended.

## [0.5.0] — 2026-10-15

Redis on large datasets. The backup path no longer holds a copy of the dataset
in memory, and restore no longer fails on any RDB that takes more than 10 s to
load. 0.4.x backups verify, fetch and restore unchanged.

### Changed

- **redis: verify parses instead of loading.** `redis-check-rdb` reads the
  compressed artifact through a pipe — the exact bytes uploaded — holding one
  key at a time and writing nothing to disk. It used to load the RDB into a
  staging `redis-server`, which needed memory equal to the dataset on every run
  and a second decompressed copy on disk.
- **redis: artifacts are zstd**, `redis-<run>.rdb.zst`. On a synthetic 174 MB
  RDB, `zstd -3` took 0.76 s against 5.4 s for `gzip -6`, at the same size.
  zstd reads `ZSTD_CLEVEL` and `ZSTD_NBTHREADS` itself; the image does not
  translate them. `.rdb.gz` runs from 0.4.x still verify and restore.
- **`FETCH_DECOMPRESS` unpacks `.zst`** as well as `.gz`.

### Fixed

- **redis: restore waited 10 s for the staging server, then called the RDB
  corrupt.** A loading server answers `LOADING`, not `PONG`. Readiness now waits
  through the load, logs progress every 10 s, and gives up at
  `REDIS_STAGE_TIMEOUT` (default 3600 s); a server that exits fails at once.
- **redis: a failed staging left its server running and its directory on the
  volume.** The directory's name is not a run name, so prune never removed it.
  In `SCHEDULE` mode the next run's server could not bind the port, the error
  was hidden, and its ping reached the leftover server — verification could
  pass against the previous run's RDB. Staging now runs as a tracked child on a
  socket in its own directory, and every failure path stops it and removes the
  directory.
- **redis: restore into a database other than 0 restored nothing, and reported
  success.** The RDB holds every database, but the staging server was scanned
  and migrated from db 0 whatever `REDIS_URL` named. Both now select the URL's
  database.
- **sqlite: `SQLITE_OPEN_RETRY_SECONDS` and `SQLITE_BUSY_TIMEOUT_MS` were never
  validated.** `require_int` checked only the first name it was given. It now
  checks every one, so a non-integer value there fails validation instead of
  reaching `sleep` and SQLite.

### Removed

- `REDIS_STAGE_PORT`. The staging server listens on a Unix socket and no TCP
  port, so nothing else can answer in its place.

### Migration

- **If you copied `restore-offline-job.yaml`, update its fetch step.** The old
  one reads `*.rdb.gz` only and finds nothing in a 0.5 run. The shipped Job
  reads both.
- Size the backup volume at about 1.5× the server's last RDB; its memory limit
  can come down. See the Redis README, "Sizing".

## [0.4.0] — 2026-10-08

A SQLite backend, the first whose data is a file rather than a server. Additive:
no environment variable changed meaning, and 0.3.0 backups restore unchanged.

### Added

- **A SQLite backend**, `ghcr.io/quyendv/platform-backup/sqlite`. The database
  is a file on a volume the container mounts. It is copied with `VACUUM INTO`
  through a read-only URI — `.backup` restarts while the database is written
  and may never finish on a busy one — and checked with `integrity_check`
  before the run is kept. Restore keeps the previous database and its `-wal`
  aside (a leftover WAL is replayed over a restored file, silently) and gives
  the new file the old one's owner and mode; it requires the application to be
  stopped. The image runs as root, with only `CHOWN`, `DAC_OVERRIDE` and
  `FOWNER` needed: only root can take part in the application's locking, and a
  copy is kept only if the file did not change while it was read. Measurements in
  `docs/superpowers/specs/2026-10-08-sqlite-backend-design.md`.

### Fixed

- **The integration suite starts again.** `minio/minio` is no longer pullable
  from Docker Hub; the fixture uses `bitnamilegacy/minio` at the same release.

## [0.3.0] — 2026-09-12

A Redis backend, and a second way to restore for the backends whose artifact is
the server's own state file. Additive: no environment variable changed meaning,
and 0.2.0 backups restore unchanged.

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

[Unreleased]: https://github.com/quyendv/platform-backup/compare/v0.5.1...HEAD
[0.5.1]: https://github.com/quyendv/platform-backup/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/quyendv/platform-backup/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/quyendv/platform-backup/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/quyendv/platform-backup/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/quyendv/platform-backup/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/quyendv/platform-backup/releases/tag/v0.1.0
