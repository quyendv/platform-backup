# platform-backup

Backup images for PostgreSQL, MongoDB, etcd and HashiCorp Vault, shipping
snapshots to any S3-compatible storage (MinIO, AWS S3, Ceph RGW, Cloudflare R2,
DigitalOcean Spaces, OVH).

Four images, one implementation. Every backend runs the same driver and obeys
the same environment contract; a backend adapter only knows how to dump and
restore its own data.

| Image | Tags |
|---|---|
| `ghcr.io/quyendv/platform-backup/postgresql` | `pg14` `pg15` `pg16` `pg17` `latest` (= pg17) |
| `ghcr.io/quyendv/platform-backup/mongodb` | `latest` |
| `ghcr.io/quyendv/platform-backup/etcd` | `latest` |
| `ghcr.io/quyendv/platform-backup/vault` | `latest` |

Per-backend documentation: [postgresql](docs/backends/postgresql.md) ·
[mongodb](docs/backends/mongodb.md) · [etcd](docs/backends/etcd.md) ·
[vault](docs/backends/vault.md)

## Quick start

```bash
docker run --rm \
  -e POSTGRES_HOST=db.internal -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=secret  -e POSTGRES_DB=appdb \
  -e AWS_ACCESS_KEY_ID=xxx -e AWS_SECRET_ACCESS_KEY=yyy \
  -e AWS_ENDPOINT_URL_S3=https://minio.example.com \
  -e S3_BUCKET=backups -e S3_PREFIX=backups/postgresql \
  ghcr.io/quyendv/platform-backup/postgresql:pg17
```

Add `-e SCHEDULE="0 2 * * *"` and the container stays up, backing up on that
cron. Leave `SCHEDULE` unset and it runs once and exits.

## Modes

`MODE` has exactly one meaning per value.

| Mode | What it does | postgresql | mongodb | vault | etcd |
|---|---|:--:|:--:|:--:|:--:|
| `backup` *(default)* | dump, upload, prune | ✅ | ✅ | ✅ | ✅ |
| `fetch` | download and verify a run into `RESTORE_DIR`, touching nothing else | ✅ | ✅ | ✅ | ✅ |
| `restore` | write a backup into the live target | ✅ | ✅ | ✅ | ❌ |

etcd refuses `restore`: restoring etcd rewrites the data directory of a
*stopped* member, so it cannot be done from a container against a live cluster.
The image says so and prints the `etcdctl` command to run on the host.

`fetch` and `restore` ignore `SCHEDULE` and always run once.

## Environment

Two groups, deliberately prefixed differently. `AWS_*` is read by the AWS CLI
itself; `S3_*` is read by this image.

**Read by the AWS CLI** — nothing here is translated or rewritten, so leaving
credentials unset falls through to an EC2 instance role or an EKS service
account (IRSA).

| Variable | Notes |
|---|---|
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` | Omit entirely to use a role |
| `AWS_REGION` | Default `us-east-1` |
| `AWS_ENDPOINT_URL_S3` | Required for anything that is not real AWS |

There is no addressing-style setting, and no `AWS_S3_ADDRESSING_STYLE`
environment variable exists in the AWS CLI. None is needed: with a custom
endpoint the CLI already uses path-style (MinIO, Ceph, R2, Spaces) and without
one it uses virtual-hosted (AWS). If a provider ever needs the override, mount
an `~/.aws/config` containing `s3.addressing_style`.

**Read by this image**

| Variable | Default | Notes |
|---|---|---|
| `MODE` | `backup` | `backup` / `fetch` / `restore` |
| `SCHEDULE` | *(empty)* | Cron expression; empty runs once and exits |
| `S3_BUCKET` | *(empty)* | **Empty keeps backups local only** |
| `S3_PREFIX` | `backups/<backend>` | Key prefix inside the bucket |
| `BACKUP_DIR` | `/backup` | |
| `RESTORE_DIR` | `/restore` | Where `fetch` writes |
| `KEEP_LOCAL` | `3` | Runs kept on disk; `0` disables pruning |
| `KEEP_REMOTE` | `30` | Runs kept in S3; `0` disables pruning |
| `RESTORE_TIMESTAMP` | *(newest)* | Pin a run, `YYYYMMDD_HHMMSS` |
| `DRY_RUN` | `false` | Log what would happen, change nothing |

Backend-specific variables are documented on each backend's page.

## Retention

Retention is a **count**, not an age: keep the newest N runs on each side.

Only whole run folders are deleted, never individual objects, so an artifact and
its checksum can never be separated. Anything under the prefix that is not
shaped exactly `YYYYMMDD_HHMMSS` is invisible to pruning and will never be
touched. `KEEP=0` disables pruning on that side — it never means "keep zero".

One consequence worth knowing: the retention *window* is `KEEP_REMOTE ×
SCHEDULE`. Moving from a four-hourly to an hourly schedule shortens how far
back 30 runs reach, from five days to a little over one.

## Layout on disk and in S3

Local and remote share one shape:

```
${BACKUP_DIR}/20260305_020000/postgresql-20260305_020000.dump.gz
                              postgresql-20260305_020000.dump.gz.sha256

s3://$S3_BUCKET/$S3_PREFIX/20260305_020000/postgresql-20260305_020000.dump.gz
                                           postgresql-20260305_020000.dump.gz.sha256
```

Timestamps are UTC. Every artifact carries a SHA-256 sidecar, and `fetch` and
`restore` verify it before doing anything with the data.

## Development

```bash
mise install          # pinned shellcheck, shfmt, hadolint, actionlint, bats
mise run check        # format check, all linters, 78 unit tests — what CI runs
mise run build        # build all images for the host architecture
mise run test:integration   # real MinIO + Postgres + Mongo, backup→restore→verify
```

`mise run check` is exactly the command CI runs, against the same pinned tool
versions.

## Migrating from the separate repositories

This replaces `quyendv/{postgresql,mongodb,etcd,vault}-backup`. The old images
keep working; they simply stop receiving updates. Environment names changed
without aliases:

| Old | New |
|---|---|
| `S3_ACCESS_KEY` | `AWS_ACCESS_KEY_ID` |
| `S3_SECRET_KEY` | `AWS_SECRET_ACCESS_KEY` |
| `S3_ENDPOINT` | `AWS_ENDPOINT_URL_S3` |
| `S3_REGION` | `AWS_REGION` |
| `S3_PATH` | `S3_PREFIX` |
| `S3_UPLOAD` | *(gone — an empty `S3_BUCKET` means local-only)* |
| `TTL_DAYS`, `RETENTION_DAYS` | *(gone — see below)* |
| `MIN_BACKUPS`, `KEEP_LAST` | *(gone — see below)* |
| `RETENTION_LOCAL_DAYS` | `KEEP_LOCAL` |
| `RETENTION_S3_DAYS` | `KEEP_REMOTE` |
| `WRITE_CHECKSUM` | *(gone — checksums are always written)* |
| `LOG_FILE` | *(gone — logs go to stderr)* |
| `RESTORE_DROP_DB` | `RESTORE_DROP` |
| `--dry-run` argument | `DRY_RUN=true` |
| `MODE=restore` on etcd | `MODE=fetch` |

Retention needs a decision rather than a rename: pick how many runs to keep
instead of how many days. `TTL_DAYS=7` on a four-hourly schedule was roughly
42 runs, so `KEEP_REMOTE=42` preserves the old window.

Artifact filenames changed too (`postgresql_backup.dump.gz` →
`postgresql-<ts>.dump.gz`), so these images cannot restore a backup taken by
the old ones. Keep the old image around until the retention window on existing
backups has passed.

## Design

[docs/superpowers/specs/2026-09-10-platform-backup-monorepo-design.md](docs/superpowers/specs/2026-09-10-platform-backup-monorepo-design.md)
records the decisions and the measurements behind them.

## License

MIT — see [LICENSE](LICENSE).
