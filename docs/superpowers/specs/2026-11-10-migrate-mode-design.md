# MODE=migrate: copy a database from one server to another

## Intent

Moving a database today means a backup, an upload to S3, then a restore. `MODE=migrate` streams directly from the source
server to the destination: no object store and no intermediate file.

It is a one-time copy. It removes the S3 hop, not the need to stop writes. Changes made on the source after the copy
has read them do not reach the destination (a full MongoDB replica-set copy replays those made during the dump), so a real cutover is: stop writes, migrate, verify, point the application at the
destination. A rehearsal or staging clone can run while the source is live, with `MIGRATE_VERIFY=false` on PostgreSQL.

## Goals

- PostgreSQL and MongoDB, through one optional adapter capability.
- The same reporting as a backup: `.last-run.json`, notifications, exit status.
- Destructive paths are opt-in and guarded before anything is changed.
- A copy that did not arrive whole fails the run.

## Non-goals

- Continuous replication or near-zero downtime (logical replication, `mongosync`). Those run for days; these images run and exit.
- Other backends. Redis, etcd, Vault, SQLite and files report that the mode is unsupported. Roadmap entry.
- Detecting that an application is still writing. The job warns at start; it cannot know.
- Resuming a failed copy. The destination is left as it is and the README says how to clean it.

## Driver (`lib/main.sh`, `entrypoint.sh`)

- `MODE` accepts `migrate`. It already runs once and ignores `SCHEDULE`, through the entrypoint's non-`backup` branch.
  A schedule must never fire a migration. Keep that, add a test, update the entrypoint's header comment.
- New capability word `migrate` in `backend_caps` and new adapter hook `backend_migrate`. Only postgresql and mongodb declare them.
- `_dispatch_mode` runs `_with_lock do_migrate`. `do_migrate` refuses a backend without the capability, the way `do_restore`
  does; sets `RUN_ID` and writes `RUN_ID_FILE` as `do_backup` does; logs a warning that writes must be stopped; calls
  `backend_migrate` bare (CLAUDE.md: nothing on the left of `||`). It needs no bucket, no run directory, no checksum, no prune.
- Notifications (`lib/notify.sh`) currently say "backup" and name a storage location. When `MODE=migrate` the title says
  migrate and the location line is omitted or names the destination host only. Never a credential or URI.
- `README.md`: a `migrate` row in the Modes table.

A migration writes `.last-run.json` to `BACKUP_DIR`. The docs say not to mount a scheduled backup's volume into a migrate job.

## PostgreSQL

Existing `POSTGRES_*` are the source. New variables:

| Variable | Required | Default |
|---|---|---|
| `DEST_POSTGRES_HOST` `DEST_POSTGRES_USER` `DEST_POSTGRES_PASSWORD` `DEST_POSTGRES_DB` | yes, in migrate | |
| `DEST_POSTGRES_PORT` | | `5432` |
| `DEST_POSTGRES_MAINTENANCE_DB` | | `postgres` |
| `MIGRATE_DROP` | | `false`: replace the destination database |
| `MIGRATE_VERIFY` | | `true`: compare row counts afterwards |

`RESTORE_GLOBALS`, `RESTORE_CREATE` and `RESTORE_NO_OWNER` keep their meaning from restore. `RESTORE_CLEAN` and `RESTORE_DROP` are not
used by migrate.

`backend_validate` checks configuration only, in migrate mode: the required variables, the booleans, and that with
`RESTORE_CREATE` the two database names are equal (`--create` always uses the source's name).

The source password stays in the exported `PGPASSWORD`. Every destination client gets its own with a per-command
`PGPASSWORD="$DEST_POSTGRES_PASSWORD"`, so neither is passed in an argument or logged.

`backend_migrate`, in order. Everything through step 3 happens before anything on the destination changes:

1. Probe both servers with `pg_isready`, naming a database (source: `POSTGRES_DB`; destination: maintenance DB).
2. Refuse the same database: compare `pg_postmaster_start_time()` of both servers and the database name. Equal on both is
   refused; it catches a hostname alias, needs no privilege on any version, and a physical clone or replica of the source
   is a different postmaster. Same server with a different database name is a legitimate clone. A failed query dies by name.
3. Inspect the destination and refuse. Existence is read on the maintenance DB. Emptiness needs a connection to the destination
   database itself when it exists, because the catalogs describe only the connected database:
   - it exists, is non-empty, and `MIGRATE_DROP` is off. Non-empty means a relation (`r p v m S f`) outside system schemas
     that is not a member of an extension, so a platform's pre-installed extensions do not count;
   - it exists, `RESTORE_CREATE` is on, and `MIGRATE_DROP` is off.
4. With `MIGRATE_DROP`: terminate sessions and drop it, as restore does. Log a warning.
5. With `RESTORE_GLOBALS`: stream `pg_dumpall --globals-only` (with `--no-role-passwords` when the source user is not a superuser, and
   `-l "$POSTGRES_DB"` as `_dump_globals` does) through `_without_role "$DEST_POSTGRES_USER"` into `psql` on the maintenance DB, as restore does.
   Same tolerance as restore: a role that already exists is reported and kept, no `ON_ERROR_STOP`. Anything truly missing surfaces when `pg_restore` assigns it.
6. Without `RESTORE_CREATE`, if the database does not exist now: a plain `CREATE DATABASE`, quoted, with the same log line
   as plain `RESTORE_DROP` about what is not carried.
7. `pg_dump --format=custom | pg_restore` with no gzip, `-d <dest db>`, or `-d <maintenance db> --create` with `RESTORE_CREATE`;
   `--no-owner --no-acl` with `RESTORE_NO_OWNER`. Read both statuses and name which side failed. `pg_restore` exits 1 when
   any statement failed, which fails the run.
8. With `MIGRATE_VERIFY`: exact row counts for each ordinary table outside system schemas, plus the number of large objects, on both
   sides; compare with `ORDER BY ... COLLATE "C"` output under `PGCLIENTENCODING=UTF8` so encodings and collations cannot differ the
   comparison. A difference fails the run, names up to 20 tables and says a still-written source is the usual cause.

Exact counts scan every table; on a very large database set `MIGRATE_VERIFY=false`.

Tag rule for the docs: `pg_dump` must be at least the source's major and `pg_restore` must not be newer than the destination
supports (17+ sends `SET transaction_timeout`, which 15 and 16 reject). Use the image of the **destination's** major when
upgrading. Downgrades are not supported.

## MongoDB

`MONGODB_URI` is the source. New variable `DEST_MONGODB_URI`, required in migrate. `MIGRATE_DROP` is not offered here:
`mongorestore --drop` against a destination that is really the source would destroy it, and without a server-identity
query the image cannot rule that out through a hostname alias. If `MIGRATE_DROP` is true, die with that explanation.

The image has the database tools but no `mongosh`. Measured on 8.0.12, and these drive the design:

- A destination URI that keeps a database in its path with `--nsFrom/--nsTo` restores nothing and exits 0. With a URI naming no database it works.
- `mongodump --archive=/dev/null` on a URI logs one ``writing `db.coll` `` line per collection, and nothing for an empty database.
- `mongodump` logs ``done dumping `ns` (N document[s])``. `mongorestore` logs ``finished restoring `ns` (N document[s], M failure[s])``.

`backend_migrate`, in order:

1. Parse only the database path and the host list. Never log a URI, only a host list with credentials removed.
2. Names: source names database A or none (S). Destination names B or none (D).
   - S none, D named: refuse. A full copy has no single target name.
   - S none, D none: full copy.
   - A, D none: same name.
   - A, B equal: same name. A, B different: rename.
3. Refuse when the host lists are equal (case-insensitive, order-insensitive) and the target name is the same.
4. Build the destination connection: remove the database from the URI path; if the URI had a database and no `authSource` option, add
   `authSource=<that database>`, because removing the path would otherwise move authentication to `admin`.
5. Destination must be empty: `mongodump --uri=<stripped> [--db=<target>] --archive=/dev/null`, stderr captured. A `writing` line for any namespace outside
   `admin`, `config`, `local` refuses the run. A failed listing dies by name and says the destination account needs read access as well as `restore`.
6. Stream `mongodump --uri=<source> --archive [--oplog] | mongorestore --uri=<stripped> --archive [--oplogReplay] [--nsFrom='A.*' --nsTo='B.*']`.
   `--oplog` per the existing `_want_oplog`. No gzip. The dump's stderr goes to a temp file, replayed to stderr after; the restore's
   is teed live and to a temp file. Read both statuses, name the failing side, remove the temp files on every path.
7. Verify from the two logs, always: for each namespace in the dump outside `admin`, `config`, `local` and any `system.buckets.*`, applying the
   rename, the restore log must report the same document count and 0 failures. A difference fails the run and names up to 20 namespaces. If the dump listed no
   namespace at all, fail: the source database does not exist or holds nothing.

A full copy carries the source's users and roles, as a full restore does: `mongorestore` merges them into the destination's (measured on 8.0.12). Destination users of other names stay,
and a same-named user keeps the destination's credentials. Say so in the docs. Time-series collections are stored as `system.buckets.*`, which the restore log names differently, so count verification
does not cover them; only `mongorestore`'s own failure reporting does. Say so in the docs.

Docs: the destination account needs `restore`, and read access for the emptiness check; the source account as for backup. A failed copy leaves a partial
destination that has to be dropped by hand before retrying.

## Environment contract

Every new variable goes in the adapter, `.env.example`, `k8s/*.yaml` where the restore variables are, `docker/compose.yaml` likewise, the backend's README,
and the table in `README.md`. A `k8s/migrate-job.yaml` for postgresql and mongodb, modelled on `restore-job.yaml`.

## Testing

Unit tests in `test/unit/` for the driver (capability refusal, migrate ignores `SCHEDULE`, no bucket needed, state recorded, a failed step recorded) and each adapter's
guards and argument building, each asserting no destructive call happened on a refused path. Stubs record args.

`test/integration/run.sh`, real servers, asserting real state:

- postgresql: fresh destination same name with globals and `RESTORE_CREATE`; rename; refused non-empty destination leaves it intact; `MIGRATE_DROP` replaces it;
  same-database refusal through a second hostname for the same server, leaving rows intact; an upgrade from 15 to 18 with the pg18 image; unprivileged destination with `RESTORE_NO_OWNER`.
- mongodb: same name, rename, a destination URI with its own user and no `authSource`, a full copy to a server with its own root user, a non-empty destination refused and intact, an oplog
  copy from the replica-set fixture, a missing source database failing.

## Release

Part of 0.9.0, which has not been tagged: add to its CHANGELOG section. Roadmap gains Redis migrate and a pointer to continuous replication.

## Left to the builder

Helper names and placement, log wording, the shape of the notifier's location line, and test structure.
