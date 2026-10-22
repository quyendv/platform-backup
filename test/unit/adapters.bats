#!/usr/bin/env bats
#
# Each adapter must fail when its dump tool fails.
#
# The driver cannot enforce this. backend_dump ends by echoing the artifact
# filename, so the function's own status reflects that echo, and errexit is
# disabled inside the tested context the driver calls it from. An adapter that
# does not check its own tool reports success and the run fails three steps
# later as "artifact too small" — pointing at the wrong thing.

# Every @test body is its own subshell, which is exactly where these variables
# are meant to live; shellcheck reads that as an accidental scope.
# shellcheck disable=SC2030,SC2031
bats_require_minimum_version 1.5.0

setup() {
  set -euo pipefail
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  source "$REPO_ROOT/lib/log.sh"
  source "$REPO_ROOT/lib/env.sh"

  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  PATH="$STUB_BIN:$PATH"
  RUN_ID=20260101_000000
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK"
}

# A stub that fails, plus permissive stubs for everything else the adapter
# touches on the way.
stub() {
  local name="$1" exit_code="${2:-0}"
  cat >"$STUB_BIN/$name" <<STUB
#!/usr/bin/env bash
exit $exit_code
STUB
  chmod +x "$STUB_BIN/$name"
}

@test "postgresql fails when pg_dump fails" {
  source "$REPO_ROOT/backends/postgresql/backend.sh"
  export POSTGRES_HOST=h POSTGRES_PORT=5432 POSTGRES_USER=u POSTGRES_DB=d
  stub pg_isready 0
  stub pg_dump 1

  run backend_dump "$WORK"

  [ "$status" -ne 0 ]
  [[ "$output" == *"pg_dump failed"* ]]
}

@test "mongodb fails when mongodump fails" {
  source "$REPO_ROOT/backends/mongodb/backend.sh"
  export MONGODB_URI=mongodb://x
  stub mongodump 1

  run backend_dump "$WORK"

  [ "$status" -ne 0 ]
  [[ "$output" == *"mongodump failed"* ]]
}

@test "etcd fails when the snapshot fails" {
  source "$REPO_ROOT/backends/etcd/backend.sh"
  export ETCDCTL_ENDPOINTS=https://x ETCDCTL_CACERT=/dev/null
  export ETCDCTL_CERT=/dev/null ETCDCTL_KEY=/dev/null
  stub etcdctl 1

  run backend_dump "$WORK"

  [ "$status" -ne 0 ]
  [[ "$output" == *"snapshot save failed"* ]]
}

@test "vault fails when the snapshot fails" {
  source "$REPO_ROOT/backends/vault/backend.sh"
  export VAULT_ADDR=http://x VAULT_TOKEN=t
  stub vault 1

  run backend_dump "$WORK"

  [ "$status" -ne 0 ]
  [[ "$output" == *"snapshot save failed"* ]]
}

@test "postgresql succeeds and echoes only the filename" {
  source "$REPO_ROOT/backends/postgresql/backend.sh"
  export POSTGRES_HOST=h POSTGRES_PORT=5432 POSTGRES_USER=u POSTGRES_DB=d
  stub pg_isready 0
  stub pg_dump 0

  # --separate-stderr, because stdout is the return value here and bats
  # otherwise folds the log lines into it — the very mixing this asserts against.
  run --separate-stderr backend_dump "$WORK"

  [ "$status" -eq 0 ]
  [ "$output" = "postgresql-20260101_000000.dump.gz" ]
  [[ "$stderr" == *"pg_dump"* ]]
}

@test "sqlite fails when VACUUM INTO fails" {
  source "$REPO_ROOT/backends/sqlite/backend.sh"
  printf 'SQLite format 3\000' >"$WORK/app.db"
  export SQLITE_PATH="$WORK/app.db"
  stub sqlite3 1

  run backend_dump "$WORK"

  [ "$status" -ne 0 ]
  [[ "$output" == *"VACUUM INTO failed"* ]]
}

# --- mongodb: --oplog on replica sets -----------------------------------------

# A mongodump that records its arguments and writes a valid archive.
stub_recording() {
  local name="$1"
  cat >"$STUB_BIN/$name" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$BATS_TEST_TMPDIR/$name-args"
for a in "\$@"; do
  case "\$a" in --archive=*) printf 'x' | gzip >"\${a#--archive=}" ;; esac
done
exit 0
STUB
  chmod +x "$STUB_BIN/$name"
}

@test "oplog auto adds --oplog when the URI names a replica set" {
  source "$REPO_ROOT/backends/mongodb/backend.sh"
  export MONGODB_URI='mongodb://u:p@db-0:27017,db-1:27017/?replicaSet=rs0&authSource=admin'
  stub_recording mongodump

  run --separate-stderr backend_dump "$WORK"

  [ "$status" -eq 0 ]
  [ "$output" = "mongodb-20260101_000000.oplog.archive.gz" ]
  run cat "$BATS_TEST_TMPDIR/mongodump-args"
  [[ "$output" == *"--oplog"* ]]
}

@test "oplog auto skips when the URI has a database path" {
  source "$REPO_ROOT/backends/mongodb/backend.sh"
  export MONGODB_URI='mongodb://u:p@db-0:27017/appdb?replicaSet=rs0'
  stub_recording mongodump

  run --separate-stderr backend_dump "$WORK"

  [ "$status" -eq 0 ]
  [ "$output" = "mongodb-20260101_000000.archive.gz" ]
  run cat "$BATS_TEST_TMPDIR/mongodump-args"
  [[ "$output" != *"--oplog"* ]]
}

@test "oplog auto skips a standalone server" {
  source "$REPO_ROOT/backends/mongodb/backend.sh"
  export MONGODB_URI='mongodb://u:p@db-0:27017/?authSource=admin'
  stub_recording mongodump

  run --separate-stderr backend_dump "$WORK"

  [ "$output" = "mongodb-20260101_000000.archive.gz" ]
}

@test "MONGODUMP_OPLOG=false never adds it" {
  source "$REPO_ROOT/backends/mongodb/backend.sh"
  export MONGODB_URI='mongodb://db-0/?replicaSet=rs0' MONGODUMP_OPLOG=false
  stub_recording mongodump

  run --separate-stderr backend_dump "$WORK"

  run cat "$BATS_TEST_TMPDIR/mongodump-args"
  [[ "$output" != *"--oplog"* ]]
}

@test "an invalid MONGODUMP_OPLOG is rejected" {
  source "$REPO_ROOT/backends/mongodb/backend.sh"
  export MONGODB_URI='mongodb://db-0' MONGODUMP_OPLOG=sometimes

  run backend_validate

  [ "$status" -ne 0 ]
  [[ "$output" == *"MONGODUMP_OPLOG"* ]]
}

@test "restore adds --oplogReplay for an .oplog.archive.gz artifact" {
  source "$REPO_ROOT/backends/mongodb/backend.sh"
  export MONGODB_URI='mongodb://db-0/?replicaSet=rs0'
  stub_recording mongorestore

  run backend_restore "$WORK/mongodb-20260101_000000.oplog.archive.gz"

  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/mongorestore-args"
  [[ "$output" == *"--oplogReplay"* ]]
}

@test "restore of a plain archive does not replay an oplog" {
  source "$REPO_ROOT/backends/mongodb/backend.sh"
  export MONGODB_URI='mongodb://db-0'
  stub_recording mongorestore

  run backend_restore "$WORK/mongodb-20260101_000000.archive.gz"

  run cat "$BATS_TEST_TMPDIR/mongorestore-args"
  [[ "$output" != *"--oplogReplay"* ]]
}

# --- postgresql: globals -------------------------------------------------------

# A stub that reads its stdin to the end, as the real tool does. One that exits
# without reading races the writer into SIGPIPE, which pipefail reports as a
# failure — on CI, not on a fast laptop.
stub_draining() {
  cat >"$STUB_BIN/$1" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
exit 0
STUB
  chmod +x "$STUB_BIN/$1"
}

# psql answers the superuser question with $1; pg_dumpall records its arguments.
stub_pg_globals() {
  local superuser="$1"
  stub pg_isready 0
  stub pg_dump 0
  cat >"$STUB_BIN/psql" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$BATS_TEST_TMPDIR/psql-args"
# The rolsuper query has no stdin to drain; applying globals pipes SQL in.
if [[ "\$*" == *rolsuper* ]]; then
  printf '%s\n' "$superuser"
else
  cat >/dev/null
fi
exit 0
STUB
  cat >"$STUB_BIN/pg_dumpall" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$BATS_TEST_TMPDIR/pg_dumpall-args"
printf 'CREATE ROLE app;\n'
STUB
  chmod +x "$STUB_BIN/psql" "$STUB_BIN/pg_dumpall"
}

@test "globals: a superuser dump keeps role passwords" {
  source "$REPO_ROOT/backends/postgresql/backend.sh"
  export POSTGRES_HOST=h POSTGRES_PORT=5432 POSTGRES_USER=u POSTGRES_PASSWORD=p POSTGRES_DB=d
  backend_validate
  stub_pg_globals t

  run --separate-stderr backend_dump "$WORK"

  [ "$status" -eq 0 ]
  [ "$output" = "postgresql-20260101_000000.dump.gz" ]
  [ -f "$WORK/globals-20260101_000000.sql.gz" ]
  run cat "$BATS_TEST_TMPDIR/pg_dumpall-args"
  [[ "$output" == *"--globals-only"* ]]
  [[ "$output" == *"-l d"* ]]
  [[ "$output" != *"--no-role-passwords"* ]]
}

@test "globals: a non-superuser dump adds --no-role-passwords" {
  source "$REPO_ROOT/backends/postgresql/backend.sh"
  export POSTGRES_HOST=h POSTGRES_PORT=5432 POSTGRES_USER=u POSTGRES_PASSWORD=p POSTGRES_DB=d
  backend_validate
  stub_pg_globals f

  run --separate-stderr backend_dump "$WORK"

  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/pg_dumpall-args"
  [[ "$output" == *"--no-role-passwords"* ]]
}

@test "globals: a failed pg_dumpall fails the run" {
  source "$REPO_ROOT/backends/postgresql/backend.sh"
  export POSTGRES_HOST=h POSTGRES_PORT=5432 POSTGRES_USER=u POSTGRES_PASSWORD=p POSTGRES_DB=d
  backend_validate
  stub_pg_globals t
  stub pg_dumpall 1

  run backend_dump "$WORK"

  [ "$status" -ne 0 ]
  [[ "$output" == *"globals"* ]]
}

@test "POSTGRES_DUMP_GLOBALS=false writes no globals" {
  source "$REPO_ROOT/backends/postgresql/backend.sh"
  export POSTGRES_HOST=h POSTGRES_PORT=5432 POSTGRES_USER=u POSTGRES_PASSWORD=p POSTGRES_DB=d
  export POSTGRES_DUMP_GLOBALS=false
  backend_validate
  stub_pg_globals t

  run --separate-stderr backend_dump "$WORK"

  [ "$status" -eq 0 ]
  [ ! -e "$WORK/globals-20260101_000000.sql.gz" ]
}

@test "restore applies globals only with RESTORE_GLOBALS=true" {
  source "$REPO_ROOT/backends/postgresql/backend.sh"
  export POSTGRES_HOST=h POSTGRES_PORT=5432 POSTGRES_USER=u POSTGRES_PASSWORD=p POSTGRES_DB=d
  backend_validate
  stub_pg_globals t
  stub_draining pg_restore
  printf 'x' | gzip >"$WORK/postgresql-20260101_000000.dump.gz"
  printf 'CREATE ROLE app;' | gzip >"$WORK/globals-20260101_000000.sql.gz"

  run backend_restore "$WORK/postgresql-20260101_000000.dump.gz"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/psql-args" ]

  RESTORE_GLOBALS=true run backend_restore "$WORK/postgresql-20260101_000000.dump.gz"
  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/psql-args"
  [[ "$output" == *"-d postgres"* ]]
}

@test "RESTORE_GLOBALS=true on a run without globals fails" {
  source "$REPO_ROOT/backends/postgresql/backend.sh"
  export POSTGRES_HOST=h POSTGRES_PORT=5432 POSTGRES_USER=u POSTGRES_PASSWORD=p POSTGRES_DB=d
  backend_validate
  stub_pg_globals t
  stub_draining pg_restore
  printf 'x' | gzip >"$WORK/postgresql-20260101_000000.dump.gz"

  RESTORE_GLOBALS=true run backend_restore "$WORK/postgresql-20260101_000000.dump.gz"

  [ "$status" -ne 0 ]
  [[ "$output" == *"globals"* ]]
}

# pg_restore --list stops reading once it has the table of contents. For a dump
# larger than a pipe buffer, gunzip was then killed by SIGPIPE and pipefail
# failed the verification of every real-sized database (0.6.0, 2026-10-22).
@test "postgresql verification passes when pg_restore stops reading early" {
  source "$REPO_ROOT/backends/postgresql/backend.sh"
  cat >"$STUB_BIN/pg_restore" <<'STUB'
#!/usr/bin/env bash
head -c 1024 >/dev/null
exit 0
STUB
  chmod +x "$STUB_BIN/pg_restore"
  head -c 8000000 /dev/urandom | gzip -1 >"$WORK/big.dump.gz"

  run backend_verify "$WORK/big.dump.gz"

  [ "$status" -eq 0 ]
}

@test "postgresql verification still fails when pg_restore rejects the archive" {
  source "$REPO_ROOT/backends/postgresql/backend.sh"
  cat >"$STUB_BIN/pg_restore" <<'STUB'
#!/usr/bin/env bash
head -c 1024 >/dev/null
exit 1
STUB
  chmod +x "$STUB_BIN/pg_restore"
  head -c 8000000 /dev/urandom | gzip -1 >"$WORK/big.dump.gz"

  run backend_verify "$WORK/big.dump.gz"

  [ "$status" -ne 0 ]
}
