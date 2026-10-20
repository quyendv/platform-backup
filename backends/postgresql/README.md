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

## Docker

[`docker/compose.yaml`](docker/compose.yaml) runs the image on a schedule, with
a pinned release tag and a persistent `/backup` volume.

```bash
cd backends/postgresql/docker
cp ../.env.example .env        # POSTGRES_*, the S3 settings, SCHEDULE
docker compose up -d
docker compose run --rm backup run   # one backup now, against the same volume
docker compose ps                    # (healthy) once a run has succeeded
docker compose logs -f backup
```

**Reaching the server.** For a server on the same host with a published port,
use `host.docker.internal` as the host: the compose file maps it to the host.
For a server in another Compose project, uncomment `networks:` in the compose
file, set the name to that project's network (`docker network ls`) and use the
server's service name as the host.

Restore and fetch:

```bash
docker compose run --rm restore        # download + verify into ./restore
docker compose run --rm -e MODE=restore -e RESTORE_DROP=true restore
```

Pick the image tag to match the server's major version (`0.5.0-pg14` …
`0.5.0-pg17`), as described under [Choosing a tag](#choosing-a-tag).

An empty `SCHEDULE` becomes `0 2 * * *` (daily, 02:00 UTC) in the `backup`
service: without one the container would back up once, exit, and be restarted
by its restart policy — a backup loop.

The `/backup` volume is persistent, so `.last-run.json` survives restarts:
`docker ps` shows `(unhealthy)` once a run fails, and `NOTIFY_ON=change` works
here, unlike in Kubernetes. Set `HEALTHCHECK_MAX_AGE` as well to catch a
schedule that stopped firing. `restore` is a separate service so that a manual
fetch or restore never overwrites the scheduled job's state.

## Kubernetes

[`k8s/`](k8s/) has a CronJob and a one-shot restore Job that reuses its
Secret, so the object-store settings cannot drift between backup and restore.

Notifications are configured in the same Secret. Leave `NOTIFY_ON=failure`
there: each run is a fresh pod with an `emptyDir`, so the state file never
survives and "previous outcome" is always unknown — `change` would fire on
every run, and a recovery message can never be sent. Failures notify either
way, which is the part that matters. Mount a PersistentVolumeClaim at
`/backup` if you want both.
