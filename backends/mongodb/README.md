# mongodb

`ghcr.io/quyendv/platform-backup/mongodb`

`mongodump --gzip --archive`, a single portable archive file. Restores with
`mongorestore`.

## Variables

| Variable | Required | Default | Notes |
|---|:--:|---|---|
| `MONGODB_URI` | ✅ | — | Carries host, credentials, replica set and TLS options |
| `RESTORE_DROP` | | `false` | Pass `--drop` to `mongorestore` |
| `MONGODUMP_OPLOG` | | `auto` | `--oplog`, for a dump consistent to one point in time. `auto` adds it when the URI names a replica set (`replicaSet=` or `mongodb+srv://`) and no database. The artifact is then `mongodb-<run>.oplog.archive.gz`, and restore replays it with `--oplogReplay` |
| `DEST_MONGODB_URI` | in migrate | — | Destination URI; required in migrate |

Plus the [shared variables](../../README.md#environment).

URI forms:

```
mongodb://user:pass@db.example.com:27017/?authSource=admin
mongodb://user:pass@db.example.com:27017/mydb?replicaSet=rs0&authSource=admin
mongodb+srv://user:pass@cluster.example.com/
```

## Restore

Every case below points `S3_PREFIX` at the backup being restored.
`RESTORE_TIMESTAMP` picks a run (default: newest; see
[the main README](../../README.md#environment) for the exact format).
Set `MODE=restore` and quiesce clients first; restore is not atomic.
The behavior below was measured with MongoDB 8.0.12 and the adapter's flags.

**A URI naming a different database than the archive's fails the run.**
`mongorestore` itself exits 0 having restored nothing, so the image checks for
that and reports it. Changing the URI database is not a rename operation.

| Scenario | Set | Notes |
|---|---|---|
| Same-name rollback | `MONGODB_URI=mongodb://db.example.com/appdb RESTORE_DROP=true` for a one-database archive of `appdb` | Drops each collection in the archive before restoring it. Collections absent from the archive stay. |
| New/empty server, full dump | `MONGODB_URI=mongodb://db.example.com/` | A full dump made with a URI naming no database restores all databases and users when the restore URI also names no database. |
| New/empty database, one-database dump | `MONGODB_URI=mongodb://db.example.com/appdb` | The URI must name the same database as the archive. A one-database dump has no users or roles and no oplog. |
| Different server, same database names | Change the host in `MONGODB_URI`, keeping the database selection above | Uses the archive's database names. Select `RESTORE_DROP=true` if replacing collections on the target. |
| Different database name | `MODE=fetch`, then manual `mongorestore` with namespace mapping | Restore exposes no rename option. Use a URI naming no database and `--nsFrom='appdb.*' --nsTo='newname.*'`. |

Without `RESTORE_DROP`, documents with duplicate `_id` values are skipped
with exit 0 and documents not in the backup stay. With `RESTORE_DROP`, each
collection in the archive is dropped first; collections not in the archive
stay. Neither case removes all data absent from the backup across the whole
server.

For a rename, use the `MODE=fetch` output or a shell in the image. This manual
route was measured working:

```bash
mongorestore --uri='mongodb://db.example.com/' --gzip \
  --archive='/restore/<run>/mongodb-<run>.archive.gz' \
  --nsFrom='appdb.*' --nsTo='newname.*'
```

Permissions: use the built-in `backup` role for a full dump, which includes
users and roles. A one-database dump needs `read` on that database and has
no users, roles or oplog. Use the built-in `restore` role to restore.

## Architectures

The image is amd64 and arm64. MongoDB publishes its Debian packages for x86_64
only, so the arm64 build installs the official database-tools tarball instead —
same tools, pinned by `DBTOOLS_VERSION`.

## Docker

[`docker/compose.yaml`](docker/compose.yaml) runs the image on a schedule, with
a pinned release tag and a persistent `/backup` volume.

```bash
cd backends/mongodb/docker
cp ../.env.example .env        # MONGODB_URI, the S3 settings, SCHEDULE
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

[`k8s/`](k8s/). `MONGODB_URI` carries the credentials, which is why the whole
configuration lives in a Secret.

Notifications are configured in the same Secret. Leave `NOTIFY_ON=failure`
there: each run is a fresh pod with an `emptyDir`, so the state file never
survives and "previous outcome" is always unknown — `change` would fire on
every run, and a recovery message can never be sent. Failures notify either
way, which is the part that matters. Mount a PersistentVolumeClaim at
`/backup` if you want both.

## Migrate

Set `MODE=migrate`, with `MONGODB_URI` for the source and `DEST_MONGODB_URI` for
the destination. This streams a one-time copy without S3 or an intermediate
archive. Stop writes on both sides, migrate, verify, then point clients at the
destination. Writes made on the source after the dump ends never reach the target; a full
replica-set copy replays those made during the dump, and any other copy does not.
The image has the database tools and no `mongosh`.

| Source URI database path | Destination URI database path | Result |
|---|---|---|
| None | None | Full copy |
| None | Named | Refused: a full copy has no single target name |
| `appdb` | None or `appdb` | Copy with the same name |
| `appdb` | `clone` | Rename using `--nsFrom='appdb.*' --nsTo='clone.*'` |

The destination must be empty outside `admin`, `config` and `local` for a full
copy, or empty in the target database for a selected-database copy. The
source account needs the backup permissions above. The destination account
needs `restore` and read access for the emptiness check. A failed listing fails
the run and names that requirement. Equal host lists, ignoring case and order,
with the same target name are refused before connecting.

`MIGRATE_DROP` is not offered. Setting it true is refused: without a server
identity query, a destination hidden by a hostname alias could be the source,
and `mongorestore --drop` would destroy it. A failed copy leaves a partial
destination that must be dropped by hand before retrying; there is no resume.

Measured on MongoDB 8.0.12, a destination URI that retains a database path with
`--nsFrom`/`--nsTo` restores nothing and exits 0. Migration removes the path
before calling `mongorestore`; if the URI named a database and omitted
`authSource`, it adds that database as `authSource` to preserve authentication.
Explicit `authSource` is kept. Only credential-free host lists are logged.

The emptiness check uses `mongodump --archive=/dev/null`: measured on 8.0.12,
it logs one `writing` namespace line per collection and nothing for an empty
database. The copy streams `mongodump --archive` into `mongorestore --archive`,
without gzip. `MONGODUMP_OPLOG` uses the backup rules, with `--oplogReplay` on
the destination when the dump takes an oplog.

Verification always compares the measured `done dumping` document counts with
`finished restoring` counts and zero failures, applying any rename. Missing
namespaces, differing counts and an empty or nonexistent source fail the run;
up to 20 namespaces are named. `admin`, `config`, `local` and
`system.buckets.*` are excluded from count comparison. Time-series collections
are stored as `system.buckets.*` and the restore log names them differently,
so only `mongorestore`'s own failure reporting covers them.

A full copy carries users and roles. `mongorestore` merges
them into the destination's: destination users with other names stay, and a
same-named user keeps the destination's credentials. Source users of other
names arrive with the source's credentials.

Configure the source and destination in the Compose environment file, then:

```bash
docker compose run --rm migrate
# A selected database can be renamed directly:
docker compose run --rm \
  -e MONGODB_URI='mongodb://reader:example@source.example.com/appdb?authSource=admin' \
  -e DEST_MONGODB_URI='mongodb://writer:example@destination.example.com/clone?authSource=admin' \
  migrate
```

For Kubernetes, configure `DEST_MONGODB_URI` in the referenced Secret and use
[`k8s/migrate-job.yaml`](k8s/migrate-job.yaml). `SCHEDULE` is ignored: migration
always runs once. It records `.last-run.json` in `BACKUP_DIR` and uses normal
notifications. Do not mount a scheduled backup's volume into a migration job;
the shipped examples give migration its own state directory.
