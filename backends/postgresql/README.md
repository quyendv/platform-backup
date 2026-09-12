# postgresql

`ghcr.io/quyendv/platform-backup/postgresql`

`pg_dump --format=custom`, gzipped. Restores with `pg_restore`.

## Choosing a tag

Tags follow the **server** major version: `pg14` … `pg17`, and `latest` = pg17.
`pg_dump` refuses to dump a server newer than itself, so a `pg16` image cannot
back up a PostgreSQL 17 server. Match the tag to the server, not to whatever is
newest.

## Variables

| Variable | Required | Default | Notes |
|---|:--:|---|---|
| `POSTGRES_HOST` | ✅ | — | |
| `POSTGRES_PORT` | ✅ | `5432` | |
| `POSTGRES_USER` | ✅ | — | |
| `POSTGRES_PASSWORD` | ✅ | — | |
| `POSTGRES_DB` | ✅ | — | |
| `POSTGRES_MAINTENANCE_DB` | | `postgres` | Connected to when dropping and recreating `POSTGRES_DB` |
| `RESTORE_DROP` | | `false` | Terminate connections, `DROP DATABASE`, `CREATE DATABASE` before restoring |
| `RESTORE_CLEAN` | | `false` | Pass `--clean --if-exists` to `pg_restore` |

Plus the [shared variables](../../README.md#environment).

## Restore

```bash
docker run --rm \
  -e MODE=restore -e RESTORE_DROP=true \
  -e POSTGRES_HOST=db.internal -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=secret  -e POSTGRES_DB=appdb \
  -e AWS_ACCESS_KEY_ID=xxx -e AWS_SECRET_ACCESS_KEY=yyy \
  -e AWS_ENDPOINT_URL_S3=https://minio.example.com \
  -e S3_BUCKET=backups -e S3_PREFIX=backups/postgresql \
  ghcr.io/quyendv/platform-backup/postgresql:pg17
```

`RESTORE_DROP` and `RESTORE_CLEAN` solve the same problem differently. `DROP`
gives a genuinely clean database and needs no objects to pre-exist;
`--clean --if-exists` drops objects individually and lets you keep database-level
settings, roles and extensions granted on the database itself. Use `DROP` unless
something outside the dump depends on the database object surviving.

Restoring into a database that is neither dropped nor cleaned will produce
"already exists" errors from `pg_restore`.

## Kubernetes

[`k8s/`](k8s/) has a CronJob with a
split ConfigMap/Secret, and a one-shot restore Job that reuses both so the
object-store settings cannot drift between backup and restore.
