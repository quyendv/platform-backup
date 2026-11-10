#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2016

setup() {
  set -euo pipefail
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  source "$REPO_ROOT/lib/main.sh"
  export MODE=migrate BACKUP_DIR="$BATS_TEST_TMPDIR/backup" S3_BUCKET=''
  export CALLS="$BATS_TEST_TMPDIR/calls" TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR" "$BATS_TEST_TMPDIR/bin"
  : >"$CALLS"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  backend_name() { printf fake; }
  backend_caps() { printf migrate; }
  backend_validate() { :; }
  backend_migrate() { printf 'migrate\n' >>"$CALLS"; }
}

@test "migrate records success and a run id without a bucket or artifacts" {
  run main
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = migrate ]
  [ "$(jq -r .outcome "$BACKUP_DIR/.last-run.json")" = success ]
  [[ "$(jq -r .run_id "$BACKUP_DIR/.last-run.json")" =~ ^[0-9]{8}_[0-9]{6}$ ]]
  run find "$BACKUP_DIR" -mindepth 1 -type d
  [ "$status" -eq 0 ]
  [ "$output" = '' ]
}

@test "migrate refuses an unsupported capability without calling the hook" {
  backend_caps() { printf 'fetch restore'; }
  run main
  [ "$status" -ne 0 ]
  [[ "$output" == *'does not support MODE=migrate'* ]]
  [ ! -s "$CALLS" ]
}

@test "migrate records an unchecked failed step and stops" {
  backend_migrate() {
    false
    printf bad >>"$CALLS"
  }
  run main
  [ "$status" -ne 0 ]
  [ ! -s "$CALLS" ]
  [ "$(jq -r .outcome "$BACKUP_DIR/.last-run.json")" = failure ]
}

@test "migrate notification subject names the mode and omits storage" {
  run env MODE=migrate bash -c 'set -euo pipefail; source "$1/lib/main.sh"; _notify_subject success postgresql; _notify_target' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *'postgresql migrate'* ]]
  [[ "$output" != *'local only'* && "$output" != *'s3://'* ]]
}

pg_setup() {
  unset -f backend_migrate
  source "$REPO_ROOT/backends/postgresql/backend.sh"
  export POSTGRES_HOST=source.example.com POSTGRES_PORT=5432 POSTGRES_USER=source_user
  export POSTGRES_PASSWORD=source_password POSTGRES_DB=app
  export DEST_POSTGRES_HOST=destination.example.com DEST_POSTGRES_USER=dest_user
  export DEST_POSTGRES_PASSWORD=dest_password DEST_POSTGRES_DB=app
  export EXISTS=f NONEMPTY=f SOURCE_START=source DEST_START=dest
  cat >"$BATS_TEST_TMPDIR/bin/pg-client" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
name="${0##*/}"
printf '%s [%s] %s\n' "$name" "${PGPASSWORD:-}" "$*" >>"$CALLS"
[[ "${FAIL:-}" != "$name" ]] || exit 7
case "$name" in
  psql)
    sql="$(cat)"
    for arg in "$@"; do
      if [[ "$arg" == SELECT* ]]; then sql="$arg"; fi
    done
    printf '%s\n' "$sql" >>"$CALLS"
    if [[ -n "${FAIL_SQL:-}" && "$sql" == *"$FAIL_SQL"* ]]; then exit 7; fi
    if [[ "${READONLY_SOURCE:-false}" == true && "$*" == *source.example.com* && "$sql" =~ (CREATE|INSERT|DROP) ]]; then exit 7; fi
    case "$sql" in
      *current_database*) printf '%s\n' "${ACTUAL_SOURCE_DB:-$POSTGRES_DB}" ;;
      *pg_postmaster_start_time*)
        if [[ "$*" == *source.example.com* ]]; then printf '%s\n' "$SOURCE_START"; else printf '%s\n' "$DEST_START"; fi ;;
      *pg_database*) printf '%s\n' "$EXISTS" ;;
      *pg_depend*) printf '%s\n' "$NONEMPTY" ;;
      *rolsuper*) printf '%s\n' "${SUPERUSER:-t}" ;;
      *pg_largeobject_metadata*)
        if [[ "$*" == *source.example.com* ]]; then printf '%s\n' "${SOURCE_COUNTS:-public.widgets|3}"; else printf '%s\n' "${DEST_COUNTS:-public.widgets|3}"; fi ;;
    esac ;;
  pg_dump) printf archive ;;
  pg_dumpall) printf 'CREATE ROLE dest_user;\nCREATE ROLE reader;\n' ;;
  pg_restore) cat >/dev/null ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/pg-client"
  local tool
  for tool in psql pg_isready pg_dump pg_dumpall pg_restore; do
    ln -s pg-client "$BATS_TEST_TMPDIR/bin/$tool"
  done
}

pg_migrate() {
  backend_validate
  backend_migrate
}

no_pg_changes() {
  run grep -E '^(pg_dump|pg_restore|pg_dumpall) |DROP DATABASE|CREATE DATABASE' "$CALLS"
  [ "$status" -eq 1 ]
  [ "$output" = '' ]
}

@test "postgres migrate requires destination configuration" {
  pg_setup
  unset DEST_POSTGRES_PASSWORD
  run pg_migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *DEST_POSTGRES_PASSWORD* ]]
  no_pg_changes
}

@test "postgres migrate validates booleans and create names before connecting" {
  pg_setup
  MIGRATE_DROP=typo run pg_migrate
  [ "$status" -ne 0 ]
  [ ! -s "$CALLS" ]
  RESTORE_CREATE=true DEST_POSTGRES_DB=other run pg_migrate
  [ "$status" -ne 0 ]
  [ ! -s "$CALLS" ]
}

@test "postgres migrate refuses a hostname alias for the same database before drop" {
  pg_setup
  DEST_START=source MIGRATE_DROP=true run pg_migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *'same database'* ]]
  no_pg_changes
}

@test "postgres migrate refuses a source connection string naming the destination" {
  pg_setup
  ACTUAL_SOURCE_DB=app POSTGRES_DB='dbname=app' DEST_START=source MIGRATE_DROP=true run pg_migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *'same database'* ]]
  no_pg_changes
}

@test "postgres migrate refuses a destination connection string before connecting" {
  pg_setup
  DEST_POSTGRES_DB='dbname=app' run backend_validate
  [ "$status" -ne 0 ]
  [[ "$output" == *'plain database name'* ]]
  [ ! -s "$CALLS" ]
}

@test "postgres migrate permits another database on the same postmaster" {
  pg_setup
  DEST_START=source DEST_POSTGRES_DB=clone run pg_migrate
  [ "$status" -eq 0 ]
  [[ "$(cat "$CALLS")" == *'-d clone'* ]]
}

@test "postgres migrate refuses nonempty destination and create over existing" {
  pg_setup
  EXISTS=t NONEMPTY=t run pg_migrate
  [ "$status" -ne 0 ]
  no_pg_changes
  EXISTS=t RESTORE_CREATE=true run pg_migrate
  [ "$status" -ne 0 ]
  no_pg_changes
}

@test "postgres migrate names probe and identity query failures before changes" {
  pg_setup
  FAIL=pg_isready run pg_migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *pg_isready* ]]
  no_pg_changes
  FAIL=psql run pg_migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *psql* ]]
  no_pg_changes
}

@test "postgres migrate streams create globals and no-owner using destination passwords per command" {
  pg_setup
  SUPERUSER=f RESTORE_CREATE=true RESTORE_GLOBALS=true RESTORE_NO_OWNER=true RESTORE_CLEAN=true RESTORE_DROP=true run pg_migrate
  [ "$status" -eq 0 ]
  local calls
  calls="$(cat "$CALLS")"
  [[ "$calls" == *'pg_dump [source_password]'*'--format=custom'* ]]
  [[ "$calls" == *'pg_restore [dest_password]'*'-d postgres --create --no-owner --no-acl'* ]]
  [[ "$calls" == *'pg_dumpall [source_password]'*'-l app --globals-only'* ]]
  [[ "$calls" == *'--no-role-passwords'* && "$calls" == *'CREATE ROLE reader;'* ]]
  [[ "$calls" != *'CREATE ROLE dest_user;'* ]]
  [[ "$calls" != *'--clean'* && "$calls" != *'--drop'* ]]
}

@test "postgres migrate quotes destructive database SQL and creates after drop" {
  pg_setup
  DEST_POSTGRES_DB="odd'\"name" MIGRATE_DROP=true run pg_migrate
  [ "$status" -eq 0 ]
  local calls
  calls="$(cat "$CALLS")"
  [[ "$calls" == *"datname = :'name'"* ]]
  [[ "$calls" == *'DROP DATABASE IF EXISTS :"name";'* ]]
  [[ "$calls" == *'CREATE DATABASE :"name";'* ]]
}

@test "postgres migrate names either side of a failed stream" {
  pg_setup
  FAIL=pg_dump run pg_migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *'pg_dump failed'* ]]
  FAIL=pg_restore run pg_migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *'pg_restore failed'* ]]
}

@test "postgres migrate verification detects differing counts and can be disabled" {
  pg_setup
  DEST_COUNTS='public.widgets|2' run pg_migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *'public.widgets'* && "$output" == *'source'* ]]
  MIGRATE_VERIFY=false DEST_COUNTS='public.widgets|2' run pg_migrate
  [ "$status" -eq 0 ]
}

mongo_setup() {
  unset -f backend_migrate
  source "$REPO_ROOT/backends/mongodb/backend.sh"
  export MONGODB_URI='mongodb://reader:password@source.example.com/app?authSource=admin'
  export DEST_MONGODB_URI='mongodb://writer:password@destination.example.com/app?authSource=admin'
  export DUMP_LOG='done dumping app.widgets (3 documents)'
  export RESTORE_LOG='finished restoring app.widgets (3 documents, 0 failures)'
  cat >"$BATS_TEST_TMPDIR/bin/mongodump" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'mongodump %s\n' "$*" >>"$CALLS"
if [[ "$*" == *--archive=/dev/null* ]]; then
  printf '%s\n' "${LIST_LOG:-}" >&2
  exit "${LIST_STATUS:-0}"
fi
printf archive
printf '%s\n' "$DUMP_LOG" >&2
exit "${DUMP_STATUS:-0}"
STUB
  cat >"$BATS_TEST_TMPDIR/bin/mongorestore" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'mongorestore %s\n' "$*" >>"$CALLS"
cat >/dev/null
printf '%s\n' "$RESTORE_LOG" >&2
exit "${RESTORE_STATUS:-0}"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/"mongo*
}

mongo_migrate() {
  backend_validate
  backend_migrate
}

no_mongo_restore() {
  run grep '^mongorestore ' "$CALLS"
  [ "$status" -eq 1 ]
  [ "$output" = '' ]
}

@test "mongo migrate requires a destination and refuses drop without exposing a URI" {
  mongo_setup
  unset DEST_MONGODB_URI
  run mongo_migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *DEST_MONGODB_URI* ]]
  no_mongo_restore
  DEST_MONGODB_URI='mongodb://destination.example.com/' MIGRATE_DROP=true run mongo_migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *'hostname alias'* && "$output" != *'mongodb://'* ]]
  no_mongo_restore
}

@test "mongo migrate refuses a full copy into one database" {
  mongo_setup
  MONGODB_URI='mongodb://source.example.com/' run mongo_migrate
  [ "$status" -ne 0 ]
  no_mongo_restore
}

@test "mongo migrate refuses case and order insensitive matching hosts before listing" {
  mongo_setup
  MONGODB_URI='mongodb://u:p@B.example.com,a.example.com/app' DEST_MONGODB_URI='mongodb://v:p@A.example.com,b.example.com/app' run mongo_migrate
  [ "$status" -ne 0 ]
  [ ! -s "$CALLS" ]
}

@test "mongo migrate strips destination database retains authSource and renames namespaces" {
  mongo_setup
  DEST_MONGODB_URI='mongodb://writer:password@destination.example.com/clone?replicaSet=rs0' RESTORE_LOG='finished restoring clone.widgets (3 documents, 0 failures)' run mongo_migrate
  [ "$status" -eq 0 ]
  local calls
  calls="$(cat "$CALLS")"
  [[ "$calls" == *'--uri=mongodb://writer:password@destination.example.com/?replicaSet=rs0&authSource=clone'* ]]
  [[ "$calls" == *'--db=clone --archive=/dev/null'* ]]
  [[ "$calls" == *'--nsFrom=app.* --nsTo=clone.*'* ]]
  [[ "$calls" != *'--gzip'* && "$calls" != *'--drop'* ]]
  [[ "$output" != *'mongodb://'* && "$output" != *password* ]]
  [ -z "$(find "$TMPDIR" -type f -print)" ]
}

@test "mongo migrate adds no authSource to a destination without credentials" {
  mongo_setup
  DEST_MONGODB_URI='mongodb://destination.example.com/clone' RESTORE_LOG='finished restoring clone.widgets (3 documents, 0 failures)' run mongo_migrate
  [ "$status" -eq 0 ]
  [[ "$(cat "$CALLS")" == *'--uri=mongodb://destination.example.com/ '* || "$(cat "$CALLS")" == *'--uri=mongodb://destination.example.com/'$'\n'* ]]
  [[ "$(cat "$CALLS")" != *'destination.example.com/?'* ]]
}

@test "mongo migrate preserves explicit authentication database" {
  mongo_setup
  DUMP_LOG=$'done dumping `app.widgets` (1 document)\nfailed mongodb://reader:password@source.example.com/app' RESTORE_LOG=$'finished restoring `app.widgets` (1 document, 0 failures)\nfailed mongodb+srv://writer:password@destination.example.com/app\nerror MONGODB://writer:password@destination.example.com/app' run mongo_migrate
  [ "$status" -eq 0 ]
  [[ "$output" != *'mongodb://'* && "$output" != *'mongodb+srv://'* && "$output" != *password* ]]
  [[ "$(cat "$CALLS")" == *'destination.example.com/?authSource=admin'* ]]
  [[ "$(cat "$CALLS")" != *'authSource=app'* ]]
}

@test "mongo migrate refuses nonempty destination and failed listing by name" {
  mongo_setup
  LIST_LOG='writing `app.widgets` to archive' run mongo_migrate
  [ "$status" -ne 0 ]
  no_mongo_restore
  LIST_STATUS=7 LIST_LOG='error mongodb://writer:password@destination.example.com/' run mongo_migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *mongodump* && "$output" == *'read access'* && "$output" != *'mongodb://'* ]]
  no_mongo_restore
  [ -z "$(find "$TMPDIR" -type f -print)" ]
}

@test "mongo migrate tolerates system databases during full destination listing and uses oplog" {
  mongo_setup
  MONGODB_URI='mongodb://source.example.com/?replicaSet=rs0' DEST_MONGODB_URI='mongodb://destination.example.com/' LIST_LOG='writing admin.system.users to archive' run mongo_migrate
  [ "$status" -eq 0 ]
  [[ "$(cat "$CALLS")" == *'--oplog'* && "$(cat "$CALLS")" == *'--oplogReplay'* ]]
}

@test "mongo migrate exempts no database when one is selected" {
  mongo_setup
  DEST_MONGODB_URI='mongodb://destination.example.com/clone' LIST_LOG='writing admin.widgets to archive' run mongo_migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *'non-empty'* ]]
  [[ "$(cat "$CALLS")" != *'mongorestore'* ]]
}

@test "mongo migrate fails either side of stream and removes logs" {
  mongo_setup
  DUMP_STATUS=7 run mongo_migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *'mongodump failed'* ]]
  [ -z "$(find "$TMPDIR" -type f -print)" ]
  RESTORE_STATUS=7 run mongo_migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *'mongorestore failed'* ]]
  [ -z "$(find "$TMPDIR" -type f -print)" ]
}

@test "mongo migrate verifies counts failures missing namespaces and missing source" {
  mongo_setup
  local bad
  for bad in 'finished restoring app.widgets (3 documents)' 'finished restoring app.widgets (2 documents, 0 failures)' 'finished restoring app.widgets (3 documents, 1 failure)' ''; do
    RESTORE_LOG="$bad" run mongo_migrate
    [ "$status" -ne 0 ]
    [[ "$output" == *app.widgets* ]]
    [ -z "$(find "$TMPDIR" -type f -print)" ]
  done
  DUMP_LOG='' run mongo_migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *'source database'* ]]
}

@test "mongo migrate excludes time-series buckets from count verification" {
  mongo_setup
  DUMP_LOG='done dumping app.system.buckets.metrics (3 documents)' RESTORE_LOG='finished restoring app.metrics (3 documents, 0 failures)' run mongo_migrate
  [ "$status" -eq 0 ]
  [[ "$(cat "$CALLS")" == *mongorestore* ]]
}

@test "mongo migrate refuses a failed namespace inspection without restoring" {
  mongo_setup
  cat >"$BATS_TEST_TMPDIR/bin/awk" <<'STUB'
#!/usr/bin/env bash
exit 7
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/awk"
  run mongo_migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *'destination namespace inspection failed'* ]]
  no_mongo_restore
  [ -z "$(find "$TMPDIR" -type f -print)" ]
}

@test "mongo migrate reports both failed sides when restore closes the stream" {
  mongo_setup
  cat >"$BATS_TEST_TMPDIR/bin/mongorestore" <<'STUB'
#!/usr/bin/env bash
exit 8
STUB
  cat >"$BATS_TEST_TMPDIR/bin/mongodump" <<'STUB'
#!/usr/bin/env bash
[[ "$*" != *--archive=/dev/null* ]] || exit 0
printf '%s\n' 'failed dumping' >&2
exit 7
STUB
  run mongo_migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *'mongodump failed'* && "$output" == *'mongorestore failed'* ]]
  [ -z "$(find "$TMPDIR" -type f -print)" ]
}

@test "mongo migrate names failed host normalization before connecting" {
  mongo_setup
  _migrate_host_key() { return 7; }
  run mongo_migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *'host normalization failed'* ]]
  [ ! -s "$CALLS" ]
}

@test "postgres migrate stops after a named destination SQL failure" {
  pg_setup
  FAIL_SQL='DROP DATABASE' MIGRATE_DROP=true run pg_migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *'psql failed dropping'* ]]
  run grep '^pg_restore ' "$CALLS"
  [ "$status" -eq 1 ]
  [ "$output" = '' ]
  FAIL_SQL='CREATE DATABASE' run pg_migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *'psql failed creating'* ]]
}

@test "postgres migrate verifies counts without source write privileges" {
  pg_setup
  READONLY_SOURCE=true run pg_migrate
  [ "$status" -eq 0 ]
  [[ "$(cat "$CALLS")" == *pg_largeobject_metadata* ]]
}
