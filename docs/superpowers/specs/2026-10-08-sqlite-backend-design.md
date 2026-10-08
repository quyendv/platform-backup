# sqlite backend — design

Date: 2026-10-08
Status: draft, awaiting review
Scope: one SQLite database file per run, read from a mounted volume. Other files
next to it (uploads, caches) are out of scope.

## Why this needs a record

SQLite is the first backend whose data is a file, not a server. Every other
adapter talks to a process over the network; this one has to sit next to the
file, and three measured facts below decide how it copies and restores it. Anyone
revisiting "just `cp` it" or "`.backup` is the official way" should read them
first.

## Measurements

Run on 2026-10-08 against SQLite 3.49.2 (Alpine 3.22 `sqlite` package), the
database in WAL mode, a separate process committing 50-row transactions in a
loop.

**`.backup` restarts while the source is being written, and may never finish.**
On a 154 MB database with a writer running for 20 s:

```
VACUUM INTO during writes: 87650 rows, integrity_check ok, returned at once
.backup during writes:     returned after 20.0 s, 337900 rows
```

The online backup API restarts its copy whenever another connection changes the
source. On a small database (1.5 MB) it usually wins the race; on a large one
under steady writes it only completes once the writer pauses. A nightly backup of
a busy application could run indefinitely. `VACUUM INTO` copies inside a single
read transaction: one consistent snapshot (every count was a multiple of the
writer's transaction size, so no torn transaction), never restarted, and the
output is in rollback-journal mode with no `-wal` to carry.

**A leftover `-wal` overrides a restored file.** A database was replaced with a
restored copy while the previous database's `-wal` and `-shm` stayed next to it:

```
restored file opened next to the old WAL -> old1,old-in-wal   (integrity_check ok)
```

The restored row is gone. SQLite replayed the old WAL over the new file and
reported no error. Restore must move the `-wal` and `-shm` away with the file
they belong to.

**An open, idle connection cannot be detected from another process.** With an
application holding the database open in WAL mode (no transaction running):

```
BEGIN EXCLUSIVE: granted       wal_checkpoint(TRUNCATE): 0|0|0
```

Nothing refuses. The `-wal` and `-shm` files exist while it is open and are
removed on a clean close, but an application killed without closing leaves them
too, so their presence proves nothing either way. Replacing the file under a
running application is undetectable here and fatal there (it keeps writing to the
old inode). Restore therefore requires the application to be stopped, and says
so; it does not pretend to check.

Compression, for sizing: 1.5 MB of JSON-like rows gzip to 55 KB; random blobs do
not compress at all.

## Design

`backends/sqlite/backend.sh`, following the adapter contract (`lib/` unchanged):

| Function | Behaviour |
|---|---|
| `backend_name` | `sqlite` |
| `backend_caps` | `fetch restore` |
| `backend_validate` | `SQLITE_PATH` required; the file exists, is readable, and opens as SQLite (`PRAGMA schema_version`) |
| `backend_dump <dir>` | `sqlite3 "$SQLITE_PATH" ".timeout $SQLITE_BUSY_TIMEOUT_MS" "VACUUM INTO '<dir>/<name>.sqlite'"`, then `gzip`; each command's status is checked; echoes `<name>.sqlite.gz` |
| `backend_verify <path>` | decompress to a temporary file, `PRAGMA integrity_check` must print exactly `ok` |
| `backend_restore <path>` | see below |

Restore, in order, stopping at the first failure:

1. Decompress to `<SQLITE_PATH>.restore-<run>` in the same directory (same
   filesystem, so the final `mv` is atomic) and run `integrity_check` on it.
2. Move the current database and its `-wal`, `-shm` and `-journal`, whichever
   exist, to `<name>.pre-restore-<run>[-wal|-shm|-journal]`. Nothing is deleted:
   the previous state stays recoverable until someone removes it.
3. `mv` the restored file to `SQLITE_PATH`.

The restored file is in rollback-journal mode (`VACUUM INTO` output); an
application that sets WAL mode on open switches it back.

Variables:

| Variable | Default | Meaning |
|---|---|---|
| `SQLITE_PATH` | — | The database file, as mounted in the container |
| `SQLITE_BUSY_TIMEOUT_MS` | `10000` | How long `VACUUM INTO` waits for a lock |

Image: the shared base plus the distribution's `sqlite` package. One image, no
matrix: the SQLite file format is backward compatible and `VACUUM INTO` needs
3.27+, which every supported base exceeds.

## Running it

The container needs the database's volume mounted, read-write (SQLite opens the
`-shm` file for writing even to read a WAL database). With a ReadWriteOnce volume
that means the same node as the application: in Kubernetes, a `podAffinity` on
the application's pod labels, and the same `fsGroup` so file permissions match.
`k8s/cronjob.yaml` ships with both, as placeholders.

## Limitations, to be documented with the backend

- Restore requires the application to be stopped (measured above: it cannot be
  detected). In Kubernetes, a GitOps controller that heals replicas will restart
  it; suspend that first.
- One file per run. Attached databases and files next to the database are not
  included.
- The backup holds a read transaction for the length of `VACUUM INTO`; in WAL
  mode that delays checkpoints, not writers.

## Testing

- Unit (bats): validation errors, the dump command's failure is propagated, the
  name, restore's moves (current file and each sidecar, the order, nothing
  deleted), a failed integrity check stops restore before anything moves.
- Integration: a real SQLite in WAL mode with a writer running during the dump;
  the artifact passes `integrity_check` and holds a whole number of the writer's
  transactions; restore over a database that has a leftover `-wal`, then the
  restored rows are the ones read back.
- `test/smoke.sh`: the image's `sqlite3` runs and supports `VACUUM INTO`.
