# postgresql

`ghcr.io/quyendv/platform-backup/postgresql`

`pg_dump --format=custom`, gzipped. Restores with `pg_restore`.

## Choosing a tag

Tags follow the **server** major version: `pg15` … `pg18`, and `latest` = pg18.
Match the tag to the server, not to whatever is newest, in both directions:

- `pg_dump` refuses to dump a server newer than itself, so a `pg17` image cannot
  back up a PostgreSQL 18 server;
- `pg_restore` 17 and later always sends `SET transaction_timeout`, which a 15
  or 16 server rejects, so a newer image's restore into an older server fails.

PostgreSQL 14 reaches end of life on 2026-11-12 and has no image from 0.8.0 on.
`0.7.0-pg14` stays published. The `pg15` image also backs up and restores a
14 server (checked on 14 with data, roles and grants), which is the way to
move a 14 deployment onto current images ahead of a server upgrade.

## Variables

| Variable | Required | Default | Notes |
|---|:--:|---|---|
| `POSTGRES_HOST` | ✅ | — | |
| `POSTGRES_PORT` | ✅ | `5432` | |
| `POSTGRES_USER` | ✅ | — | |
| `POSTGRES_PASSWORD` | ✅ | — | |
| `POSTGRES_DB` | ✅ | — | |
| `POSTGRES_MAINTENANCE_DB` | | `postgres` | Connected to for `RESTORE_DROP` and `RESTORE_CREATE` |
| `RESTORE_DROP` | | `false` | Terminate connections and drop the database; create it empty unless `RESTORE_CREATE=true` |
| `RESTORE_CREATE` | | `false` | Pass `--create` to `pg_restore` on the maintenance database; requires the archive name to match `POSTGRES_DB`; incompatible with `RESTORE_CLEAN` |
| `RESTORE_NO_OWNER` | | `false` | Pass `--no-owner --no-acl`; restored objects belong to the restoring role and archived grants are skipped |
| `RESTORE_CLEAN` | | `false` | Pass `--clean --if-exists` to `pg_restore` |
| `POSTGRES_DUMP_GLOBALS` | | `true` | Also write `pg_dumpall --globals-only` (roles, memberships, tablespaces) as `globals-<run>.sql.gz`. Without superuser rights it adds `--no-role-passwords` |
| `RESTORE_GLOBALS` | | `false` | Apply the run's globals before restoring. For a fresh server: on a live one it would overwrite roles changed since the backup |

Plus the [shared variables](../../README.md#environment).

## Restore

Every case below sets `MODE=restore` and points `S3_PREFIX` at the prefix of the
backup being restored. `RESTORE_TIMESTAMP` selects a run (default: newest);
see [the main README](../../README.md#environment) for its exact format.
**Quiesce clients before restoring.** Restore is not atomic.

| Scenario | Set | Notes |
|---|---|---|
| Roll back a database to its own backup, keeping database-level properties | `RESTORE_DROP=true RESTORE_CREATE=true` | Terminates connections and drops the database, then `pg_restore --create` restores its owner, encoding, locale, database-level grants and database/role-in-database settings. The archive name must equal `POSTGRES_DB`. Referenced roles must exist. |
| Roll back, keeping the database object | `RESTORE_CLEAN=true` | Drops and restores objects with `--clean --if-exists`; keeps the existing database object and its properties rather than restoring those properties from the backup. |
| Fresh server, same name | `RESTORE_CREATE=true RESTORE_GLOBALS=true` | The database must not exist. Globals create roles before `pg_restore --create` assigns the database owner. Dumps made by a non-superuser have no role passwords; set them afterwards. |
| Existing empty database created by a platform (managed service, non-superuser) | `RESTORE_NO_OWNER=true`; no drop, create or clean flags | Restores into the existing database as the connecting role, skipping archived owners and grants. The existing database's properties remain. |
| Copy under a different name | `POSTGRES_DB=new RESTORE_DROP=true` | Creates an empty database, then copies data and objects. The source database's owner, encoding, database-level grants and settings are not carried. Roles referenced by object GRANTs must exist, or set `RESTORE_NO_OWNER=true`. |

`RESTORE_CREATE` and `RESTORE_CLEAN` cannot be combined. With
`RESTORE_CREATE`, an existing database requires `RESTORE_DROP=true`; a name
mismatch is refused before anything is dropped. To restore under another
name, unset `RESTORE_CREATE`.

The source's locale must exist on the target with `RESTORE_CREATE`. With
`RESTORE_DROP`, a failure after the drop leaves the database gone, so test on
a scratch server first when moving between OS images. Match the image tag to
the server's major version in both directions, as described under
[Choosing a tag](#choosing-a-tag).

`RESTORE_GLOBALS` applies roles, memberships and tablespaces before
`pg_restore`; globals alone do not carry database-level properties. On a live
server, applying globals can overwrite roles changed since the backup.
`RESTORE_NO_OWNER` works with or without `RESTORE_CREATE` and skips both
owners and grants. Without drop or clean, restoring into a populated database
can produce "already exists" errors.

```bash
docker run --rm \
  -e MODE=restore -e RESTORE_DROP=true \
  -e POSTGRES_HOST=db.example.com -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=example  -e POSTGRES_DB=appdb \
  -e AWS_ACCESS_KEY_ID=xxx -e AWS_SECRET_ACCESS_KEY=yyy \
  -e AWS_ENDPOINT_URL_S3=https://minio.example.com \
  -e S3_BUCKET=backups -e S3_PREFIX=backups/postgresql \
  ghcr.io/quyendv/platform-backup/postgresql:pg17
```

## Permissions

Backup, measured on PostgreSQL 18, does not require a superuser, but it needs
read access to everything being dumped. On PostgreSQL 14 and later:

```sql
GRANT pg_read_all_data TO backup_user;
GRANT CONNECT ON DATABASE appdb TO backup_user;
ALTER ROLE backup_user BYPASSRLS;
```

Tables with row-level security fail the dump without `BYPASSRLS`. Large
objects can still fail with `permission denied` and need their owner or a
superuser. A failed dump fails the run; data is never silently omitted.
Including role passwords in globals requires a superuser.

Restore with `RESTORE_DROP` or `RESTORE_CREATE` needs `CREATEDB` and ownership
of any database being dropped; `RESTORE_DROP` also needs `pg_signal_backend` to
end other roles' sessions. Restoring owners and grants needs a superuser
or membership in those roles; otherwise use `RESTORE_NO_OWNER=true`.
`pg_restore` exits 1 if any statement failed, so the run is reported failed.

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

Pick the image tag to match the server's major version (`0.9.0-pg15` …
`0.9.0-pg18`), as described under [Choosing a tag](#choosing-a-tag).

With `SCHEDULE` set, `docker compose up -d` leaves the container running and
backing up on that cron; add `RESTART_POLICY=unless-stopped` to `.env` so it
comes back after a reboot. With `SCHEDULE` empty it takes one backup and exits,
like the image itself, and the restart policy has to stay at its default `no`:
otherwise every exit restarts it, and one backup becomes a loop.

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
