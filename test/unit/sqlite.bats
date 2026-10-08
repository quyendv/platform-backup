#!/usr/bin/env bats
#
# The sqlite adapter, against real databases (sqlite3 is pinned in mise.toml).
# Three measured facts are pinned here: the dump never creates files beside a
# database nobody has open, a leftover -wal never reaches a restored file, and a
# damaged artifact stops restore before anything is moved.

# Every @test body is its own subshell, which is exactly where these variables
# are meant to live; shellcheck reads that as an accidental scope.
# shellcheck disable=SC2030,SC2031
bats_require_minimum_version 1.5.0

setup() {
  set -euo pipefail
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  source "$REPO_ROOT/lib/log.sh"
  source "$REPO_ROOT/lib/env.sh"
  source "$REPO_ROOT/backends/sqlite/backend.sh"
  RUN_ID=20260101_000000
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK"
}

# db FILE SQL...: run statements on a database file.
db() {
  local file="$1"
  shift
  sqlite3 "$file" "$@" >/dev/null
}

# A WAL database that was closed cleanly: no -wal, no -shm.
closed_wal_db() {
  db "$1" 'PRAGMA journal_mode=WAL;' 'CREATE TABLE t(v);' "INSERT INTO t VALUES ('a'),('b');"
  rm -f -- "$1-wal" "$1-shm"
}

@test "a WAL database nobody has open is read immutable" {
  closed_wal_db "$WORK/a.db"
  SQLITE_PATH="$WORK/a.db" run _sqlite_source_uri
  [ "$status" -eq 0 ]
  [ "$output" = "file:$WORK/a.db?mode=ro&immutable=1" ]
}

@test "a WAL database with its -shm beside it is read with locks" {
  closed_wal_db "$WORK/a.db"
  : >"$WORK/a.db-shm"
  SQLITE_PATH="$WORK/a.db" run _sqlite_source_uri
  [ "$status" -eq 0 ]
  [ "$output" = "file:$WORK/a.db?mode=ro" ]
}

@test "a rollback-journal database is read with locks" {
  db "$WORK/a.db" 'CREATE TABLE t(v);'
  SQLITE_PATH="$WORK/a.db" run _sqlite_source_uri
  [ "$status" -eq 0 ]
  [ "$output" = "file:$WORK/a.db?mode=ro" ]
}

@test "dump writes a gzip whose database is whole, and creates nothing beside the source" {
  closed_wal_db "$WORK/a.db"
  mkdir -p "$WORK/out"

  SQLITE_PATH="$WORK/a.db" run --separate-stderr backend_dump "$WORK/out"

  [ "$status" -eq 0 ]
  [ "$output" = "sqlite-20260101_000000.sqlite.gz" ]
  gunzip -c "$WORK/out/$output" >"$WORK/check.db"
  [ "$(sqlite3 "$WORK/check.db" 'PRAGMA integrity_check')" = ok ]
  [ "$(sqlite3 "$WORK/check.db" 'SELECT count(*) FROM t')" = 2 ]
  [ ! -e "$WORK/a.db-wal" ]
  [ ! -e "$WORK/a.db-shm" ]
  [ ! -e "$WORK/out/dump.sqlite" ]
}

@test "validate refuses a database that does not exist yet" {
  SQLITE_PATH="$WORK/none.db" run backend_validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "validate refuses a file that is not a database" {
  printf 'not a database' >"$WORK/a.db"
  SQLITE_PATH="$WORK/a.db" run backend_validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not open as a SQLite database"* ]]
}

@test "validate accepts a database" {
  closed_wal_db "$WORK/a.db"
  SQLITE_PATH="$WORK/a.db" run backend_validate
  [ "$status" -eq 0 ]
  [ ! -e "$WORK/a.db-shm" ]
}

@test "verify refuses a damaged database" {
  printf 'SQLite format 3\000garbage' | gzip >"$WORK/bad.sqlite.gz"
  run backend_verify "$WORK/bad.sqlite.gz"
  [ "$status" -ne 0 ]
}

@test "verify accepts a whole database" {
  db "$WORK/a.db" 'CREATE TABLE t(v);'
  gzip -c "$WORK/a.db" >"$WORK/a.sqlite.gz"
  BACKUP_DIR="$WORK" run backend_verify "$WORK/a.sqlite.gz"
  [ "$status" -eq 0 ]
}

@test "restore keeps the old database and its WAL, which never reaches the restored file" {
  db "$WORK/new.db" 'CREATE TABLE t(v);' "INSERT INTO t VALUES ('restored');"
  gzip -c "$WORK/new.db" >"$WORK/art.sqlite.gz"
  closed_wal_db "$WORK/a.db"
  printf 'stale' >"$WORK/a.db-wal"
  printf 'stale' >"$WORK/a.db-shm"

  SQLITE_PATH="$WORK/a.db" run backend_restore "$WORK/art.sqlite.gz"

  [ "$status" -eq 0 ]
  [ "$(sqlite3 "$WORK/a.db" 'SELECT v FROM t')" = restored ]
  [ -e "$WORK/a.db.pre-restore-20260101_000000" ]
  [ -e "$WORK/a.db.pre-restore-20260101_000000-wal" ]
  [ -e "$WORK/a.db.pre-restore-20260101_000000-shm" ]
  [ ! -e "$WORK/a.db.restore-20260101_000000" ]
}

@test "restore stops before moving anything when the artifact is damaged" {
  db "$WORK/a.db" 'CREATE TABLE t(v);'
  printf 'SQLite format 3\000garbage' | gzip >"$WORK/bad.sqlite.gz"

  SQLITE_PATH="$WORK/a.db" run backend_restore "$WORK/bad.sqlite.gz"

  [ "$status" -ne 0 ]
  [ -e "$WORK/a.db" ]
  run find "$WORK" -name '*pre-restore*'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "restore gives the new file the old file's mode" {
  db "$WORK/new.db" 'CREATE TABLE t(v);'
  gzip -c "$WORK/new.db" >"$WORK/art.sqlite.gz"
  db "$WORK/a.db" 'CREATE TABLE t(v);'
  chmod 0660 "$WORK/a.db"

  SQLITE_PATH="$WORK/a.db" run backend_restore "$WORK/art.sqlite.gz"

  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$WORK/a.db")" = 660 ]
}

@test "restore into an empty place puts the database there" {
  db "$WORK/new.db" 'CREATE TABLE t(v);'
  gzip -c "$WORK/new.db" >"$WORK/art.sqlite.gz"

  SQLITE_PATH="$WORK/a.db" run backend_restore "$WORK/art.sqlite.gz"

  [ "$status" -eq 0 ]
  [ "$(sqlite3 "$WORK/a.db" 'PRAGMA integrity_check')" = ok ]
}

@test "fetch needs no database: it only reads the object store" {
  unset SQLITE_PATH
  MODE=fetch run backend_validate
  [ "$status" -eq 0 ]
}

@test "restore accepts a damaged or missing database: that is what it is for" {
  printf 'not a database' >"$WORK/a.db"
  MODE=restore SQLITE_PATH="$WORK/a.db" run backend_validate
  [ "$status" -eq 0 ]
  MODE=restore SQLITE_PATH="$WORK/none.db" run backend_validate
  [ "$status" -eq 0 ]
}

@test "restore needs the directory the database goes in" {
  MODE=restore SQLITE_PATH="$WORK/missing/a.db" run backend_validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing"* ]]
}

@test "a read that fails while the application reopens its database is tried again" {
  closed_wal_db "$WORK/a.db"
  mkdir -p "$WORK/bin" "$WORK/out"
  local real
  real="$(command -v sqlite3)"
  # Fails twice (as on a read-only mount while the -shm is being recreated), then works.
  cat >"$WORK/bin/sqlite3" <<STUB
#!/usr/bin/env bash
n=\$(cat "$WORK/calls" 2>/dev/null || echo 0); echo \$((n + 1)) >"$WORK/calls"
[[ "\$1" == "--version" ]] && exec "$real" "\$@"
if ((n < 2)); then echo "Error: unable to open database file (14)" >&2; exit 1; fi
exec "$real" "\$@"
STUB
  chmod +x "$WORK/bin/sqlite3"

  PATH="$WORK/bin:$PATH" SQLITE_PATH="$WORK/a.db" SQLITE_OPEN_RETRY_SECONDS=0 run --separate-stderr backend_dump "$WORK/out"

  [ "$status" -eq 0 ]
  [ "$output" = "sqlite-20260101_000000.sqlite.gz" ]
}

@test "a read that keeps failing gives up with the reason" {
  closed_wal_db "$WORK/a.db"
  mkdir -p "$WORK/bin" "$WORK/out"
  cat >"$WORK/bin/sqlite3" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && { echo 3.49.2; exit 0; }
echo "Error: unable to open database file (14)" >&2
exit 1
STUB
  chmod +x "$WORK/bin/sqlite3"

  PATH="$WORK/bin:$PATH" SQLITE_PATH="$WORK/a.db" SQLITE_OPEN_RETRY_SECONDS=0 run backend_dump "$WORK/out"

  [ "$status" -ne 0 ]
  [[ "$output" == *"VACUUM INTO failed"* ]]
  [[ "$output" == *"unable to open database file"* ]]
}

@test "an attempt that left a partial copy does not block the next one" {
  closed_wal_db "$WORK/a.db"
  mkdir -p "$WORK/bin" "$WORK/out"
  local real
  real="$(command -v sqlite3)"
  # The first attempt writes half a file and fails, as an interrupted VACUUM INTO can.
  cat >"$WORK/bin/sqlite3" <<STUB
#!/usr/bin/env bash
[[ "\$1" == "--version" ]] && exec "$real" "\$@"
if [[ "\$*" == *"VACUUM INTO"* && ! -e "$WORK/failed-once" ]]; then
  : >"$WORK/failed-once"; printf 'partial' >"$WORK/out/dump.sqlite"
  echo "Error: unable to open database file (14)" >&2; exit 1
fi
exec "$real" "\$@"
STUB
  chmod +x "$WORK/bin/sqlite3"

  PATH="$WORK/bin:$PATH" SQLITE_PATH="$WORK/a.db" SQLITE_OPEN_RETRY_SECONDS=0 run --separate-stderr backend_dump "$WORK/out"

  [ "$status" -eq 0 ]
  gunzip -c "$WORK/out/$output" >"$WORK/check.db"
  [ "$(sqlite3 "$WORK/check.db" 'PRAGMA integrity_check')" = ok ]
}

@test "restore runs without a run id: the kept file is named by the time of the restore" {
  db "$WORK/new.db" 'CREATE TABLE t(v);'
  gzip -c "$WORK/new.db" >"$WORK/art.sqlite.gz"
  db "$WORK/a.db" 'CREATE TABLE t(v);'
  unset RUN_ID

  SQLITE_PATH="$WORK/a.db" run backend_restore "$WORK/art.sqlite.gz"

  [ "$status" -eq 0 ]
  local kept
  kept="$(find "$WORK" -name 'a.db.pre-restore-*' -print -quit)"
  [[ "$(basename "$kept")" =~ ^a\.db\.pre-restore-[0-9]{8}_[0-9]{6}$ ]]
}
