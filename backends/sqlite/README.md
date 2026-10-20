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
- **As root, with the application's locks.** SQLite readers record what they
  read in the `-shm`; a reader that cannot write it (another uid's file, or a
  read-only mount) is invisible to the application, which can then checkpoint
  over pages under the copy. Measured with a writer that never pauses: read-only
  mounts needed up to 9 attempts and sometimes never got a copy; as root with a
  writable mount, 5 runs out of 5 needed none. SQLite run as root gives the
  `-wal`/`-shm` it creates to the database's owner, so nothing it leaves behind
  is unusable to the application. The image runs as root; drop every
  capability but `CHOWN`, `DAC_OVERRIDE` and `FOWNER`.
- **The database is never opened for writing** (`mode=ro`), and a copy is kept
  only if the file's inode, size and mtime did not move while it was read.
- **Not as root** (a platform that forbids it): a WAL database with no `-shm`
  is read `immutable=1` so no file owned by this image's user is created, the
  same check guards the copy, and errors are tried again; expect retries, or no
  copy at all, while the application writes without pause.
- **Opening is tried again**, `SQLITE_OPEN_RETRIES` attempts
  `SQLITE_OPEN_RETRY_SECONDS` apart, on any error: a read that meets a
  checkpoint fails with "database disk image is malformed", which is not a
  property of the database.
- In WAL mode the read transaction delays checkpoints while the copy runs; it
  never blocks writers.

## Variables

| Variable | Required | Default | Notes |
|---|:--:|---|---|
| `SQLITE_PATH` | ✅ | — | The database file, as mounted in the container |
| `SQLITE_BUSY_TIMEOUT_MS` | | `10000` | How long `VACUUM INTO` waits for a lock |
| `SQLITE_OPEN_RETRIES` | | `10` | Attempts at opening the database |
| `SQLITE_OPEN_RETRY_SECONDS` | | `1` | Pause between attempts |

Plus the [shared variables](../../README.md#environment).

## Running it

Mount the database's volume read-write and run as root (the image's default)
with only the capabilities it needs:

```bash
docker run --rm --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
  -v app-data:/data \
  -e SQLITE_PATH=/data/app.db \
  -e AWS_ACCESS_KEY_ID=xxx -e AWS_SECRET_ACCESS_KEY=yyy \
  -e AWS_ENDPOINT_URL_S3=https://minio.example.com \
  -e S3_BUCKET=backups -e S3_PREFIX=backups/sqlite \
  ghcr.io/quyendv/platform-backup/sqlite:latest
```

With a ReadWriteOnce volume the container must run on the same node as the
application. [k8s/cronjob.yaml](k8s/cronjob.yaml) has the `podAffinity` and the
security context, with placeholders for the application's label and claim.

## Docker

[`docker/compose.yaml`](docker/compose.yaml) runs the image on a schedule, with
a pinned release tag and a persistent `/backup` volume.

```bash
cd backends/sqlite/docker
cp ../.env.example .env        # SQLITE_PATH, the S3 settings, SCHEDULE
echo SQLITE_VOLUME=<the application's volume> >> .env   # read by Compose only
docker compose up -d
docker compose run --rm backup run   # one backup now, against the same volume
docker compose ps                    # (healthy) once a run has succeeded
docker compose logs -f backup
```

**Mounting the database.** Set `SQLITE_VOLUME` to the application's existing
Docker volume (`docker volume ls`); it is mounted at `/data`, so `SQLITE_PATH`
is `/data/<file>`. For a bind mount, replace the `app-data` volume in the
compose file with the host directory. The service runs as root with only
`CHOWN`, `DAC_OVERRIDE` and `FOWNER`, for the reasons under
[How the copy is made](#how-the-copy-is-made).

Restore and fetch:

```bash
docker compose run --rm restore        # download + verify into ./restore
docker stop <application container>    # the application must be stopped first
docker compose run --rm -e MODE=restore restore
```

An empty `SCHEDULE` becomes `0 2 * * *` (daily, 02:00 UTC) in the `backup`
service: without one the container would back up once, exit, and be restarted
by its restart policy — a backup loop.

The `/backup` volume is persistent, so `.last-run.json` survives restarts:
`docker ps` shows `(unhealthy)` once a run fails, and `NOTIFY_ON=change` works
here, unlike in Kubernetes. Set `HEALTHCHECK_MAX_AGE` as well to catch a
schedule that stopped firing. `restore` is a separate service so that a manual
fetch or restore never overwrites the scheduled job's state.

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

With no previous file to copy from, the restored file is mode `0664` (the
volume's group can write it) and a warning says to check its owner. A symlinked
`SQLITE_PATH` restores the file the link points to.

Changing the owner needs root, which is how the image runs. Without root the
mode is kept, a warning is logged, and the owner must be fixed by hand if the
application cannot write the file.

```bash
docker run --rm --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
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
