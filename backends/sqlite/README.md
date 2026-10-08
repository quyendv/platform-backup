# sqlite

`ghcr.io/quyendv/platform-backup/sqlite`

Backs up one SQLite database file with `VACUUM INTO`, gzipped, and checks it
with `PRAGMA integrity_check` before the run is kept. The database is a file,
not a server: the container mounts the volume that holds it.

The choices below were measured; the record is
[the design](../../docs/superpowers/specs/2026-10-08-sqlite-backend-design.md).

## How the copy is made

- **`VACUUM INTO`, not `.backup`.** The online backup API restarts whenever the
  database is written and, on a large busy database, only finishes once the
  writer pauses. `VACUUM INTO` copies one consistent snapshot inside a single
  read transaction, while the application keeps writing.
- **Read-only, always.** The database is opened `mode=ro`. A WAL database with
  no `-shm` beside it is one nobody has open, and is opened `immutable=1`:
  `mode=ro` would create a `-wal`/`-shm` pair owned by this image's user, which
  the application, under its own uid, may then be unable to write.
- In WAL mode the read transaction delays checkpoints while the copy runs; it
  never blocks writers.

## Variables

| Variable | Required | Default | Notes |
|---|:--:|---|---|
| `SQLITE_PATH` | ✅ | — | The database file, as mounted in the container |
| `SQLITE_BUSY_TIMEOUT_MS` | | `10000` | How long `VACUUM INTO` waits for a lock |

Plus the [shared variables](../../README.md#environment).

## Running it

Mount the database's volume **read-write**: SQLite writes the `-shm` file even
to read a WAL database. Give the container the group that owns the
application's files (`fsGroup` in Kubernetes, `--group-add` with Docker); it
does not need the application's uid.

With a ReadWriteOnce volume the container must run on the same node as the
application. [k8s/cronjob.yaml](k8s/cronjob.yaml) has the `podAffinity` for it,
with placeholders for the application's label and claim.

```bash
docker run --rm --group-add 1000 \
  -v app-data:/data \
  -e SQLITE_PATH=/data/app.db \
  -e AWS_ACCESS_KEY_ID=xxx -e AWS_SECRET_ACCESS_KEY=yyy \
  -e AWS_ENDPOINT_URL_S3=https://minio.example.com \
  -e S3_BUCKET=backups -e S3_PREFIX=backups/sqlite \
  ghcr.io/quyendv/platform-backup/sqlite:latest
```

## Restore

**Stop the application first.** Restore replaces the file, and an open, idle
connection cannot be detected from another process; an application left
running keeps writing to the replaced file. If a controller heals replicas, a
GitOps tool with self-heal for instance, suspend it before scaling down.

Restore, stopping at the first failure:

1. Decompresses next to the database and runs `integrity_check` on it.
2. Moves the current database and its `-wal`, `-shm` and `-journal` to
   `<file>.pre-restore-<run>[-wal|-shm|-journal]`. Nothing is deleted. A
   leftover `-wal` must never stay beside a restored file: SQLite replays it
   over the new file and reports no error.
3. Gives the restored file the owner and mode of the file it replaces, and puts
   it in place.

Changing the owner needs root, so run the restore as root
([k8s/restore-job.yaml](k8s/restore-job.yaml) does). Without root the mode is
kept, a warning is logged, and the owner must be fixed by hand if the
application cannot write the file.

```bash
docker run --rm --user 0 \
  -v app-data:/data \
  -e MODE=restore -e SQLITE_PATH=/data/app.db \
  -e AWS_ACCESS_KEY_ID=xxx -e AWS_SECRET_ACCESS_KEY=yyy \
  -e AWS_ENDPOINT_URL_S3=https://minio.example.com \
  -e S3_BUCKET=backups -e S3_PREFIX=backups/sqlite \
  ghcr.io/quyendv/platform-backup/sqlite:latest
```

`RESTORE_TIMESTAMP=YYYYMMDD_HHMMSS` picks a run; empty is the newest. Remove
`<file>.pre-restore-*` once the application is healthy.

## Limits

- One file per run. Attached databases and other files on the volume are not
  included.
- `MODE=fetch` with `FETCH_DECOMPRESS=true` gives a database file to place by
  hand, for example on another machine.
