#!/usr/bin/env bash
# End-to-end: seed a real target, back it up to a real MinIO, destroy the data,
# restore it, and assert the data came back.
#
# Usage: test/integration/run.sh [backend ...]   (default: postgresql mongodb redis vault sqlite schedule notify upload_failure)
#
# etcd is not covered here: it needs a real etcd with TLS on the host network,
# and its restore runs outside the container by design. See backends/etcd/README.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE=(docker compose -f "${ROOT}/test/integration/compose.yaml")
PROJECT=platform-backup-it
NETWORK="${PROJECT}_default"
BUCKET=backups

pass() { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
info() { printf '\033[0;36m••••\033[0m %s\n' "$*"; }
fail() {
  printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2
  exit 1
}

cleanup() {
  info "Tearing down"
  "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
  docker rm -f "${PROJECT}-sqlite-writer" >/dev/null 2>&1 || true
  docker volume rm -f "${PROJECT}_sqlite_data" "${PROJECT}_sqlite_fetch" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Runs a backup image against the compose network with MinIO wired up.
backup_image() {
  local image="$1" mode="$2" prefix="$3"
  shift 3
  docker run --rm --network "$NETWORK" \
    -e MODE="$mode" \
    -e AWS_ACCESS_KEY_ID=minioadmin \
    -e AWS_SECRET_ACCESS_KEY=minioadmin \
    -e AWS_REGION=us-east-1 \
    -e AWS_ENDPOINT_URL_S3=http://minio:9000 \
    -e S3_BUCKET="$BUCKET" \
    -e S3_PREFIX="$prefix" \
    "$@" "$image"
}

s3_ls() {
  docker run --rm --network "$NETWORK" \
    -e AWS_ACCESS_KEY_ID=minioadmin -e AWS_SECRET_ACCESS_KEY=minioadmin \
    -e AWS_REGION=us-east-1 \
    amazon/aws-cli:latest --endpoint-url http://minio:9000 s3 ls "$@"
}

# Which compose service each test needs. Starting only those keeps an unrelated
# target's problems from blocking the tests that do not use it.
services_for() {
  case "$1" in
    postgresql | schedule | upload_failure) printf 'postgres' ;;
    notify) printf 'postgres notifysink' ;;
    mongodb) printf 'mongo' ;;
    mongodb_oplog) printf 'mongors' ;;
    postgresql_owner | completeness) printf 'postgres' ;;
    redis) printf 'redis' ;;
    vault) printf 'vault' ;;
  esac
}

start_stack() {
  local wanted=("$@") svc services=(minio) b
  local extra=()
  for b in "${wanted[@]}"; do
    svc="$(services_for "$b")"
    # A test can need more than one service, so split rather than append the
    # whole string as a single name.
    [[ -n "$svc" ]] || continue
    read -ra extra <<<"$svc"
    services+=("${extra[@]}")
  done
  # Deduplicate: two tests may share a target.
  mapfile -t services < <(printf '%s\n' "${services[@]}" | awk '!seen[$0]++')
  info "Starting ${services[*]}"
  "${COMPOSE[@]}" up -d --wait "${services[@]}"
  docker run --rm --network "$NETWORK" \
    -e AWS_ACCESS_KEY_ID=minioadmin -e AWS_SECRET_ACCESS_KEY=minioadmin \
    -e AWS_REGION=us-east-1 \
    amazon/aws-cli:latest --endpoint-url http://minio:9000 \
    s3 mb "s3://${BUCKET}" >/dev/null
}

psql_target() {
  "${COMPOSE[@]}" exec -T -e PGPASSWORD=secret postgres \
    psql -U postgres -d appdb -tAq -v ON_ERROR_STOP=1 "$@"
}

test_postgresql() {
  local image=ghcr.io/quyendv/platform-backup/postgresql:pg17
  local prefix=it/postgresql
  local env=(-e POSTGRES_HOST=postgres -e POSTGRES_PORT=5432
    -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=secret -e POSTGRES_DB=appdb)

  info "postgresql: seeding"
  psql_target -c "CREATE TABLE widgets (id int primary key, name text);"
  psql_target -c "INSERT INTO widgets VALUES (1,'alpha'),(2,'beta'),(3,'gamma');"
  # Bulk that does not compress, so the dump outgrows a pipe buffer: verifying
  # a dump that size failed in 0.6.0 while every small fixture passed.
  psql_target -c "CREATE TABLE bulk AS SELECT g AS id, md5(g::text) || md5((g * 7)::text) AS v FROM generate_series(1, 200000) g;"

  info "postgresql: backup"
  backup_image "$image" backup "$prefix" "${env[@]}" >/dev/null
  s3_ls "s3://${BUCKET}/${prefix}/" | grep -qE 'PRE [0-9]{8}_[0-9]{6}/' ||
    fail "postgresql: no run folder uploaded"
  pass "postgresql: backup uploaded a run folder"

  info "postgresql: destroying the data"
  psql_target -c "DROP TABLE widgets; DROP TABLE bulk;"

  info "postgresql: restore"
  backup_image "$image" restore "$prefix" "${env[@]}" >/dev/null

  local rows
  rows="$(psql_target -c "SELECT count(*) FROM widgets;")"
  [[ "$rows" == "3" ]] || fail "postgresql: expected 3 rows after restore, got '${rows}'"
  local name
  name="$(psql_target -c "SELECT name FROM widgets WHERE id=2;")"
  [[ "$name" == "beta" ]] || fail "postgresql: expected 'beta', got '${name}'"
  pass "postgresql: data survived backup -> restore"

  # A superuser's globals carry its own password. Restoring them with
  # RESTORE_GLOBALS onto a server where that password differs must not lock the
  # restore out: 0.6.1 applied it and pg_restore could no longer log in.
  info "postgresql: restore with globals after the superuser's password changed"
  psql_target -c "DROP TABLE widgets; DROP TABLE bulk; ALTER ROLE postgres PASSWORD 'changed';"
  backup_image "$image" restore "$prefix" -e POSTGRES_HOST=postgres -e POSTGRES_PORT=5432 \
    -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=changed -e POSTGRES_DB=appdb \
    -e RESTORE_GLOBALS=true >/dev/null ||
    fail "postgresql: restore with globals failed once the superuser's password differed"
  rows="$(psql_target -c "SELECT count(*) FROM widgets;")"
  psql_target -c "ALTER ROLE postgres PASSWORD 'secret';"
  [[ "$rows" == "3" ]] || fail "postgresql: expected 3 rows after the globals restore, got '${rows}'"
  pass "postgresql: globals restored without touching the connecting role"

  info "postgresql: fetch"
  backup_image "$image" fetch "$prefix" "${env[@]}" >/dev/null
  pass "postgresql: fetch verified the checksum"

  local listing
  listing="$(s3_ls --recursive "s3://${BUCKET}/${prefix}/")"
  [[ "$listing" == *"/_COMPLETE"* ]] || fail "postgresql: the run has no _COMPLETE marker"
  [[ "$listing" == *"/globals-"*".sql.gz.sha256"* ]] ||
    fail "postgresql: a superuser run wrote no checksummed globals"
  pass "postgresql: the run carries its globals and a _COMPLETE marker"

  info "postgresql: backup with read-back against the real store"
  # Captured, not piped into grep -q: grep exiting on the first match would
  # SIGPIPE the container under pipefail and read as a failure.
  local out
  out="$(backup_image "$image" backup "$prefix" "${env[@]}" -e VERIFY_READBACK=true 2>&1)" ||
    fail "postgresql: backup with read-back failed: ${out}"
  [[ "$out" == *"Read back postgresql-"* ]] || fail "postgresql: read-back did not read the artifact"
  pass "postgresql: read-back streamed the objects back and matched"
}

# Most deployments back up as the application's owner, not a superuser, and
# pg_dumpall cannot read role passwords without one. The globals must still be
# written, and applying them on restore must not break it.
test_postgresql_owner() {
  local image=ghcr.io/quyendv/platform-backup/postgresql:pg17
  local prefix=it/postgresql-owner
  local env=(-e POSTGRES_HOST=postgres -e POSTGRES_PORT=5432
    -e POSTGRES_USER=app_owner -e POSTGRES_PASSWORD=ownerpw -e POSTGRES_DB=ownerdb)

  info "postgresql_owner: an owner role and its database"
  psql_target -c "CREATE ROLE app_owner LOGIN PASSWORD 'ownerpw';"
  psql_target -c "CREATE ROLE app_reader;"
  psql_target -c "GRANT app_reader TO app_owner;"
  psql_target -c "CREATE DATABASE ownerdb OWNER app_owner;"
  "${COMPOSE[@]}" exec -T -e PGPASSWORD=ownerpw postgres \
    psql -U app_owner -d ownerdb -v ON_ERROR_STOP=1 -q \
    -c "CREATE TABLE gadgets (id int); INSERT INTO gadgets VALUES (1),(2);"

  local out
  out="$(backup_image "$image" backup "$prefix" "${env[@]}" 2>&1)" ||
    fail "postgresql_owner: backup as a non-superuser failed: ${out}"
  [[ "$out" == *"without role passwords"* ]] ||
    fail "postgresql_owner: the globals were not dumped without passwords"
  [[ "$(s3_ls --recursive "s3://${BUCKET}/${prefix}/")" == *"/globals-"* ]] ||
    fail "postgresql_owner: no globals uploaded"
  pass "postgresql_owner: a non-superuser backup writes its globals"

  "${COMPOSE[@]}" exec -T -e PGPASSWORD=ownerpw postgres \
    psql -U app_owner -d ownerdb -q -c "DROP TABLE gadgets;"
  backup_image "$image" restore "$prefix" "${env[@]}" -e RESTORE_GLOBALS=true \
    -e POSTGRES_MAINTENANCE_DB=ownerdb >/dev/null ||
    fail "postgresql_owner: restore with RESTORE_GLOBALS failed"
  local rows
  rows="$("${COMPOSE[@]}" exec -T -e PGPASSWORD=ownerpw postgres \
    psql -U app_owner -d ownerdb -tAq -c "SELECT count(*) FROM gadgets;")"
  [[ "$rows" == "2" ]] || fail "postgresql_owner: expected 2 rows, got '${rows}'"
  pass "postgresql_owner: restore applied the globals and the data"
}

# An upload that dies before its marker leaves objects that look like a run.
# Restore must skip it and take the newest run that finished.
test_completeness() {
  local image=ghcr.io/quyendv/platform-backup/postgresql:pg17
  local prefix=it/completeness
  local env=(-e POSTGRES_HOST=postgres -e POSTGRES_PORT=5432
    -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=secret -e POSTGRES_DB=appdb)

  backup_image "$image" backup "$prefix" "${env[@]}" >/dev/null
  info "completeness: planting a newer run with no marker"
  docker run --rm --network "$NETWORK" \
    -e AWS_ACCESS_KEY_ID=minioadmin -e AWS_SECRET_ACCESS_KEY=minioadmin \
    -e AWS_REGION=us-east-1 --entrypoint sh amazon/aws-cli:latest -c \
    "echo junk > /tmp/a && aws --endpoint-url http://minio:9000 s3 cp /tmp/a \
      s3://${BUCKET}/${prefix}/29991231_000000/postgresql-29991231_000000.dump.gz" >/dev/null

  local out
  out="$(backup_image "$image" fetch "$prefix" "${env[@]}" 2>&1)" ||
    fail "completeness: fetch failed: ${out}"
  [[ "$out" != *"29991231_000000"* ]] || fail "completeness: fetch chose the run with no marker"
  pass "completeness: fetch skipped the unfinished run"

  out="$(backup_image "$image" backup "$prefix" "${env[@]}" -e KEEP_REMOTE=1 2>&1)" ||
    fail "completeness: second backup failed: ${out}"
  s3_ls "s3://${BUCKET}/${prefix}/29991231_000000/" >/dev/null 2>&1 ||
    fail "completeness: a run newer than every complete run was pruned"
  pass "completeness: KEEP_REMOTE=1 kept the newest complete run and the unfinished one beside it"
}

# A backup whose upload fails must fail. Until 0.5.x it logged "Uploaded run"
# and "complete", recorded success and exited 0: the run executed with errexit
# switched off, so nothing it did not check by hand could fail it. A unit test
# stubs aws; this one proves the real CLI's exit status reaches the run.
test_upload_failure() {
  local image=ghcr.io/quyendv/platform-backup/postgresql:pg17 out rc=0
  info "upload_failure: backup against an endpoint that refuses connections"
  out="$(backup_image "$image" backup it/upload-failure \
    -e POSTGRES_HOST=postgres -e POSTGRES_PORT=5432 -e POSTGRES_USER=postgres \
    -e POSTGRES_PASSWORD=secret -e POSTGRES_DB=appdb \
    -e AWS_ENDPOINT_URL_S3=http://minio:9999 2>&1)" || rc=$?

  ((rc != 0)) || fail "upload_failure: backup exited 0 with no reachable S3"
  [[ "$out" != *"Uploaded run"* && "$out" != *"complete"* ]] ||
    fail "upload_failure: the run reported an upload that never happened"
  [[ "$out" == *"Upload of run"*"failed"* ]] ||
    fail "upload_failure: the failure did not name the upload"
  pass "upload_failure: a failed upload fails the run (exit ${rc}) and says so"
}

mongo_eval() {
  "${COMPOSE[@]}" exec -T mongo mongosh --quiet \
    -u root -p secret --authenticationDatabase admin appdb --eval "$1"
}

test_mongodb() {
  local image=ghcr.io/quyendv/platform-backup/mongodb:latest
  local prefix=it/mongodb
  local uri="mongodb://root:secret@mongo:27017/?authSource=admin"
  local env=(-e MONGODB_URI="$uri")

  info "mongodb: seeding"
  mongo_eval 'db.widgets.insertMany([{_id:1,name:"alpha"},{_id:2,name:"beta"},{_id:3,name:"gamma"}])' >/dev/null

  info "mongodb: backup"
  backup_image "$image" backup "$prefix" "${env[@]}" >/dev/null
  s3_ls "s3://${BUCKET}/${prefix}/" | grep -qE 'PRE [0-9]{8}_[0-9]{6}/' ||
    fail "mongodb: no run folder uploaded"
  pass "mongodb: backup uploaded a run folder"

  info "mongodb: destroying the data"
  mongo_eval 'db.widgets.drop()' >/dev/null

  info "mongodb: restore"
  backup_image "$image" restore "$prefix" "${env[@]}" -e RESTORE_DROP=true >/dev/null

  local count
  count="$(mongo_eval 'db.widgets.countDocuments()' | tr -d '[:space:]')"
  [[ "$count" == "3" ]] || fail "mongodb: expected 3 documents after restore, got '${count}'"
  pass "mongodb: data survived backup -> restore"
}

# A replica-set member: the dump takes an oplog, so it is one point in time,
# and restore replays it.
test_mongodb_oplog() {
  local image=ghcr.io/quyendv/platform-backup/mongodb:latest
  local prefix=it/mongodb-oplog
  local env=(-e MONGODB_URI="mongodb://mongors:27017/?replicaSet=rs0")

  "${COMPOSE[@]}" exec -T mongors mongosh --quiet appdb \
    --eval 'db.gizmos.insertMany([{_id:1},{_id:2},{_id:3},{_id:4}])' >/dev/null
  backup_image "$image" backup "$prefix" "${env[@]}" >/dev/null ||
    fail "mongodb_oplog: backup failed"
  [[ "$(s3_ls --recursive "s3://${BUCKET}/${prefix}/")" == *".oplog.archive.gz"* ]] ||
    fail "mongodb_oplog: the artifact carries no oplog"
  pass "mongodb_oplog: a replica-set dump takes an oplog"

  "${COMPOSE[@]}" exec -T mongors mongosh --quiet appdb --eval 'db.gizmos.drop()' >/dev/null
  local out
  out="$(backup_image "$image" restore "$prefix" "${env[@]}" -e RESTORE_DROP=true 2>&1)" ||
    fail "mongodb_oplog: restore failed: ${out}"
  [[ "$out" == *"replaying"* ]] || fail "mongodb_oplog: restore did not replay the oplog"
  local count
  count="$("${COMPOSE[@]}" exec -T mongors mongosh --quiet appdb \
    --eval 'db.gizmos.countDocuments()' | tr -d '[:space:]')"
  [[ "$count" == "4" ]] || fail "mongodb_oplog: expected 4 documents, got '${count}'"
  pass "mongodb_oplog: restore replayed the oplog and the data is back"
}

# The scheduled path is a different code path from a one-shot run, and it is
# the one nothing could see: a stubbed supercronic accepted a command the real
# binary could not exec, so SCHEDULE mode died at startup in every image while
# the unit tests stayed green.
test_schedule() {
  local image=ghcr.io/quyendv/platform-backup/postgresql:pg17
  local prefix=it/schedule name=pb-it-schedule

  info "schedule: starting a container with SCHEDULE set"
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" --network "$NETWORK" \
    -e SCHEDULE='* * * * *' \
    -e POSTGRES_HOST=postgres -e POSTGRES_PORT=5432 \
    -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=secret -e POSTGRES_DB=appdb \
    -e AWS_ACCESS_KEY_ID=minioadmin -e AWS_SECRET_ACCESS_KEY=minioadmin \
    -e AWS_REGION=us-east-1 -e AWS_ENDPOINT_URL_S3=http://minio:9000 \
    -e S3_BUCKET="$BUCKET" -e S3_PREFIX="$prefix" \
    "$image" >/dev/null

  # It must still be alive a few seconds later. The argv[0] bug killed it here.
  sleep 5
  [[ "$(docker inspect -f '{{.State.Running}}' "$name")" == "true" ]] || {
    docker logs "$name" 2>&1 | tail -5 >&2
    docker rm -f "$name" >/dev/null 2>&1
    fail "schedule: container exited instead of scheduling"
  }
  pass "schedule: supercronic started and stayed up"

  info "schedule: waiting for the first scheduled backup (up to ~90s)"
  local waited=0
  until s3_ls "s3://${BUCKET}/${prefix}/" 2>/dev/null | grep -qE 'PRE [0-9]{8}_[0-9]{6}/'; do
    sleep 5
    waited=$((waited + 5))
    if ((waited > 90)); then
      docker logs "$name" 2>&1 | tail -10 >&2
      docker rm -f "$name" >/dev/null 2>&1
      fail "schedule: no backup appeared within 90s"
    fi
  done
  pass "schedule: cron actually produced a backup"

  docker rm -f "$name" >/dev/null 2>&1
}

# Notifications are the one thing that must never change a run's outcome, and
# the one thing you only find out about when you needed it.
test_notify() {
  local image=ghcr.io/quyendv/platform-backup/postgresql:pg17
  local prefix=it/notify

  info "notify: a failing backup must reach the webhook"
  "${COMPOSE[@]}" exec -T notifysink sh -c 'true' >/dev/null 2>&1 || true

  # A deliberately wrong password: the dump fails, nothing is uploaded.
  docker run --rm --network "$NETWORK" \
    -e POSTGRES_HOST=postgres -e POSTGRES_PORT=5432 \
    -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=wrong -e POSTGRES_DB=appdb \
    -e AWS_ACCESS_KEY_ID=minioadmin -e AWS_SECRET_ACCESS_KEY=minioadmin \
    -e AWS_REGION=us-east-1 -e AWS_ENDPOINT_URL_S3=http://minio:9000 \
    -e S3_BUCKET="$BUCKET" -e S3_PREFIX="$prefix" \
    -e NOTIFY_ON=failure -e NOTIFY_WEBHOOK_URL=http://notifysink:8080/hook \
    "$image" >/dev/null 2>&1 && fail "notify: the backup was supposed to fail"

  local payload
  payload="$("${COMPOSE[@]}" logs notifysink 2>/dev/null | grep -o '{.*}' | tail -n1)"
  [[ -n "$payload" ]] || fail "notify: the webhook received nothing"
  # The sink wraps the request body in its own JSON, so the payload has to be
  # decoded rather than grepped.
  local outcome backend
  outcome="$(jq -r '.body | fromjson | .outcome' <<<"$payload")"
  backend="$(jq -r '.body | fromjson | .backend' <<<"$payload")"
  [[ "$outcome" == "failure" ]] ||
    fail "notify: expected outcome=failure, got '${outcome}'"
  [[ "$backend" == "postgresql" ]] ||
    fail "notify: expected backend=postgresql, got '${backend}'"
  pass "notify: a failed backup reaches the webhook with structured detail"

  info "notify: an unreachable notifier must not fail a good backup"
  docker run --rm --network "$NETWORK" \
    -e POSTGRES_HOST=postgres -e POSTGRES_PORT=5432 \
    -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=secret -e POSTGRES_DB=appdb \
    -e AWS_ACCESS_KEY_ID=minioadmin -e AWS_SECRET_ACCESS_KEY=minioadmin \
    -e AWS_REGION=us-east-1 -e AWS_ENDPOINT_URL_S3=http://minio:9000 \
    -e S3_BUCKET="$BUCKET" -e S3_PREFIX="$prefix" \
    -e NOTIFY_ON=always -e NOTIFY_WEBHOOK_URL=http://127.0.0.1:1/nope \
    -e NOTIFY_TIMEOUT=3 \
    "$image" >/dev/null 2>&1 ||
    fail "notify: an unreachable webhook turned a good backup into a failure"
  pass "notify: an unreachable webhook leaves the backup succeeding"
}

redis_exec() {
  "${COMPOSE[@]}" exec -T redis redis-cli -a secret --no-auth-warning "$@"
}

test_redis() {
  local image=ghcr.io/quyendv/platform-backup/redis:latest
  local prefix=it/redis
  local url="redis://:secret@redis:6379/0"
  local env=(-e REDIS_URL="$url")

  info "redis: seeding several types and a TTL"
  redis_exec mset k1 v1 k2 v2 k3 v3 >/dev/null
  redis_exec rpush mylist a b c >/dev/null
  redis_exec hset myhash f1 v1 f2 v2 >/dev/null
  redis_exec setex ttlkey 3600 temp >/dev/null
  [[ "$(redis_exec dbsize | tr -d '\r')" == "6" ]] || fail "redis: seed did not take"

  info "redis: backup"
  backup_image "$image" backup "$prefix" "${env[@]}" >/dev/null
  s3_ls "s3://${BUCKET}/${prefix}/" | grep -qE 'PRE [0-9]{8}_[0-9]{6}/' ||
    fail "redis: no run folder uploaded"
  pass "redis: backup uploaded a run folder"

  info "redis: destroying the data"
  redis_exec flushall >/dev/null
  [[ "$(redis_exec dbsize | tr -d '\r')" == "0" ]] || fail "redis: flush did not take"

  info "redis: restore"
  backup_image "$image" restore "$prefix" "${env[@]}" >/dev/null

  local count k2 list hash ttl
  count="$(redis_exec dbsize | tr -d '\r')"
  [[ "$count" == "6" ]] || fail "redis: expected 6 keys after restore, got '${count}'"
  k2="$(redis_exec get k2 | tr -d '\r')"
  [[ "$k2" == "v2" ]] || fail "redis: expected k2=v2, got '${k2}'"
  list="$(redis_exec lrange mylist 0 -1 | tr '\n' ' ' | tr -d '\r')"
  [[ "$list" == "a b c " ]] || fail "redis: list not restored, got '${list}'"
  hash="$(redis_exec hget myhash f2 | tr -d '\r')"
  [[ "$hash" == "v2" ]] || fail "redis: hash not restored, got '${hash}'"
  pass "redis: every data type survived backup -> restore"

  # The whole reason restore stages an RDB rather than replaying SET commands.
  ttl="$(redis_exec ttl ttlkey | tr -d '\r')"
  ((ttl > 3000 && ttl <= 3600)) || fail "redis: TTL not preserved, got '${ttl}'"
  pass "redis: TTLs survived too (${ttl}s remaining)"

  # fetch and the offline restore Job key on the extension.
  s3_ls --recursive "s3://${BUCKET}/${prefix}/" | grep -qE 'redis-[0-9]{8}_[0-9]{6}\.rdb\.zst$' ||
    fail "redis: the artifact is not zstd"
  docker run --rm --network "$NETWORK" -e MODE=fetch -e FETCH_DECOMPRESS=true \
    -e AWS_ACCESS_KEY_ID=minioadmin -e AWS_SECRET_ACCESS_KEY=minioadmin \
    -e AWS_REGION=us-east-1 -e AWS_ENDPOINT_URL_S3=http://minio:9000 \
    -e S3_BUCKET="$BUCKET" -e S3_PREFIX="$prefix" "${env[@]}" \
    --entrypoint bash "$image" -c \
    '/opt/platform-backup/entrypoint.sh >/dev/null 2>&1 && redis-check-rdb /restore/*/redis-*.rdb' \
    >/dev/null || fail "redis: FETCH_DECOMPRESS did not produce a parseable RDB from a .zst run"
  pass "redis: the artifact is zstd, and fetch unpacks it ready to place"

  test_redis_slow_load "$image" "$prefix-slow" "${env[@]}"
  redis_tooling ghcr.io/quyendv/platform-backup/redis:redis8
  redis_tooling ghcr.io/quyendv/platform-backup/redis:redis7
}

# A staging server used to get 10 s to answer PONG, and a loading server
# answers LOADING — so any RDB that took longer to load failed restore as
# "corrupt". key-load-delay (a hidden server setting) slows the load down
# without a multi-GB fixture; a wrapper applies it, so the adapter needs no seam.
test_redis_slow_load() {
  local image="$1" prefix="$2" keys=15000
  shift 2
  local env=("$@") wrapper logs count

  info "redis: a restore whose load takes longer than the old 10 s"
  redis_exec flushall >/dev/null
  redis_exec eval "for i=1,${keys} do redis.call('SET','slow:'..i,i) end" 0 >/dev/null
  backup_image "$image" backup "$prefix" "${env[@]}" >/dev/null
  redis_exec flushall >/dev/null

  wrapper="$(mktemp)"
  # A loading server only answers between chunks of
  # loading-process-events-interval-bytes (2 MB by default). This fixture is far
  # smaller, so without lowering it a ping would block for the whole load rather
  # than see LOADING, which is what a large RDB really does.
  printf '#!/bin/sh\nexec /usr/local/bin/redis-server "$@" --key-load-delay 1000 --loading-process-events-interval-bytes 1024\n' >"$wrapper"
  chmod 755 "$wrapper"
  logs="$(backup_image "$image" restore "$prefix" "${env[@]}" \
    -v "${wrapper}:/opt/slow/redis-server:ro" \
    -e PATH=/opt/slow:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin 2>&1)" || {
    rm -f "$wrapper"
    printf '%s\n' "$logs" | tail -n 5 >&2
    fail "redis: a slow-loading restore failed"
  }
  rm -f "$wrapper"

  # The progress line is first logged at 10 s, so seeing it proves the load
  # really outlasted the old budget.
  grep -q 'is loading the RDB' <<<"$logs" || {
    printf '%s\n' "$logs" | tail -n 8 >&2
    fail "redis: the load finished inside 10 s, so this proved nothing; raise key-load-delay"
  }
  count="$(redis_exec dbsize | tr -d '\r')"
  [[ "$count" == "$keys" ]] || fail "redis: expected ${keys} keys after a slow restore, got '${count}'"
  pass "redis: a restore that loads for more than 10 s completes (${count} keys)"
}

# The adapter's verify and staging against the image's real binaries: stubs
# prove the call, never that redis-check-rdb or zstd accept it.
redis_tooling() {
  local image="$1"
  info "redis: verify and staging with real binaries (${image##*:})"
  docker run --rm --entrypoint bash "$image" -c '
set -euo pipefail
cd /backup
source /opt/platform-backup/lib/log.sh
source /opt/platform-backup/lib/env.sh
source /opt/platform-backup/backend.sh
bad() { echo "FAIL: $*" >&2; exit 1; }

redis-server --port 6390 --save "" --appendonly no --daemonize yes >/dev/null
until redis-cli -p 6390 ping 2>/dev/null | grep -q PONG; do sleep 0.1; done
redis-cli -p 6390 eval "for i=1,20000 do redis.call(\"SET\",\"k\"..i,string.rep(\"v\",100)..i) end" 0 >/dev/null
redis-cli -p 6390 --rdb good.rdb >/dev/null 2>&1
redis-cli -p 6390 shutdown nosave >/dev/null 2>&1 || true

zstd -q good.rdb -o good.rdb.zst
gzip -c good.rdb >good.rdb.gz
head -c "$(($(stat -c%s good.rdb.zst) / 2))" good.rdb.zst >cut.rdb.zst
cp good.rdb flip.rdb
printf "\x55" | dd of=flip.rdb bs=1 seek="$(($(stat -c%s good.rdb) / 2))" conv=notrunc 2>/dev/null
zstd -q flip.rdb -o flip.rdb.zst

backend_verify good.rdb.zst 2>/dev/null || bad "verify rejected a good artifact"
backend_verify good.rdb.gz 2>/dev/null || bad "verify rejected a 0.4 gzip artifact"
if backend_verify cut.rdb.zst 2>/dev/null; then bad "verify accepted a truncated artifact"; fi
if backend_verify flip.rdb.zst 2>/dev/null; then bad "verify accepted a corrupt RDB"; fi

for a in good.rdb.zst good.rdb.gz; do
  _redis_stage "$a" /backup/stage 2>/dev/null
  n="$(_stage_cli dbsize)"
  _redis_stage_stop
  [ "$n" = 20000 ] || bad "staged ${n} keys from ${a}"
done
if (_redis_stage flip.rdb.zst /backup/stage 2>/dev/null); then bad "staged a corrupt RDB"; fi
[ ! -e /backup/stage ] || bad "a failed stage left its directory"
if pgrep -x redis-server >/dev/null; then bad "a failed stage left its server running"; fi

# The RDB holds every database; restore must take the URL'"'"'s, not db 0.
redis-server --port 6391 --save "" --daemonize yes >/dev/null
until redis-cli -p 6391 ping 2>/dev/null | grep -q PONG; do sleep 0.1; done
redis-cli -p 6391 -n 3 mset a 1 b 2 c 3 >/dev/null
redis-cli -p 6391 --rdb db3.rdb >/dev/null 2>&1
zstd -q db3.rdb -o db3.rdb.zst
redis-cli -p 6391 -n 3 flushdb >/dev/null
REDIS_URL=redis://127.0.0.1:6391/3 backend_restore db3.rdb.zst >/dev/null 2>&1 || bad "restore into db 3 failed"
[ "$(redis-cli -p 6391 -n 3 dbsize)" = 3 ] || bad "restore into db 3 restored $(redis-cli -p 6391 -n 3 dbsize) of 3 keys"
redis-cli -p 6391 shutdown nosave >/dev/null 2>&1 || true
' || fail "redis: real-binary verify/staging checks failed on ${image##*:}"
  pass "redis: verify catches corruption; .zst and .gz stage; restore takes the URL's db (${image##*:})"
}

vault_exec() {
  "${COMPOSE[@]}" exec -T -e VAULT_ADDR=http://127.0.0.1:8200 \
    ${VAULT_TOKEN:+-e VAULT_TOKEN="$VAULT_TOKEN"} vault "$@"
}

test_vault() {
  local image=ghcr.io/quyendv/platform-backup/vault:latest
  local prefix=it/vault
  local init unseal_key

  info "vault: initialising raft storage"
  init="$(vault_exec vault operator init -key-shares=1 -key-threshold=1 -format=json)"
  unseal_key="$(printf '%s' "$init" | jq -r '.unseal_keys_b64[0]')"
  VAULT_TOKEN="$(printf '%s' "$init" | jq -r '.root_token')"
  vault_exec vault operator unseal "$unseal_key" >/dev/null

  info "vault: seeding"
  vault_exec vault secrets enable -path=secret kv-v2 >/dev/null
  vault_exec vault kv put secret/widget name=alpha >/dev/null
  [[ "$(vault_exec vault kv get -field=name secret/widget | tr -d '\r')" == "alpha" ]] ||
    fail "vault: seed did not take"

  local env=(-e VAULT_ADDR=http://vault:8200 -e VAULT_TOKEN="$VAULT_TOKEN")

  info "vault: backup"
  backup_image "$image" backup "$prefix" "${env[@]}" >/dev/null
  s3_ls "s3://${BUCKET}/${prefix}/" | grep -qE 'PRE [0-9]{8}_[0-9]{6}/' ||
    fail "vault: no run folder uploaded"
  pass "vault: backup uploaded a run folder"

  info "vault: destroying the data"
  vault_exec vault kv metadata delete secret/widget >/dev/null
  vault_exec vault kv get secret/widget >/dev/null 2>&1 &&
    fail "vault: secret still readable after delete"

  info "vault: restore"
  backup_image "$image" restore "$prefix" "${env[@]}" >/dev/null

  # A restore seals Vault; the snapshot came from this same cluster, so the
  # original unseal key still applies.
  info "vault: unsealing after restore"
  local attempt=0
  until vault_exec vault operator unseal "$unseal_key" >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    ((attempt < 30)) || fail "vault: still sealed 30s after restore"
    sleep 1
  done

  local name
  name="$(vault_exec vault kv get -field=name secret/widget | tr -d '\r')"
  [[ "$name" == "alpha" ]] || fail "vault: expected 'alpha' after restore, got '${name}'"
  pass "vault: data survived backup -> restore"
}

# The sqlite target is a file on a volume, so the "server" is a volume and the
# application is a container writing to it as its own uid (1001), sharing only
# group 1000 with the backup image (999:1000) — the shape a Kubernetes fsGroup
# gives.
SQLITE_IMAGE=ghcr.io/quyendv/platform-backup/sqlite:latest
SQLITE_DATA="${PROJECT}_sqlite_data"
SQLITE_FETCH="${PROJECT}_sqlite_fetch"

# sqlite_as USER VOLUME SQL...: sqlite3 on the database inside a volume.
sqlite_as() {
  local user="$1" vol="$2"
  shift 2
  docker run --rm --user "$user" -v "${vol}:/data" --entrypoint sqlite3 "$SQLITE_IMAGE" "$@"
}

test_sqlite() {
  local prefix=it/sqlite rows fetched owner
  local env=(-e SQLITE_PATH=/data/app.db -v "${SQLITE_DATA}:/data")
  # Root (the image's default) with only the capabilities the README names.
  local backup_env=(-e SQLITE_PATH=/data/app.db -v "${SQLITE_DATA}:/data"
    --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER)

  info "sqlite: a WAL database owned by the application"
  docker volume create "$SQLITE_DATA" >/dev/null
  docker volume create "$SQLITE_FETCH" >/dev/null
  docker run --rm --user 0 -v "${SQLITE_DATA}:/data" -v "${SQLITE_FETCH}:/restore" --entrypoint sh "$SQLITE_IMAGE" \
    -c 'chown 1001:1000 /data && chmod 2775 /data && chown 999:1000 /restore'
  sqlite_as 1001:1000 "$SQLITE_DATA" /data/app.db \
    'PRAGMA journal_mode=WAL;' 'CREATE TABLE t(id INTEGER PRIMARY KEY, v BLOB);' >/dev/null

  info "sqlite: a writer commits 50 rows at a time for 20 s"
  docker run -d --name "${PROJECT}-sqlite-writer" --user 1001:1000 -v "${SQLITE_DATA}:/data" \
    --entrypoint sh "$SQLITE_IMAGE" -c '
      end=$(( $(date +%s) + 20 ))
      while [ "$(date +%s)" -lt "$end" ]; do
        sqlite3 /data/app.db ".timeout 5000" "INSERT INTO t(v) SELECT randomblob(1000) FROM
          (WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<50) SELECT i FROM n);"
      done' >/dev/null
  sleep 3

  info "sqlite: backup while it writes"
  backup_image "$SQLITE_IMAGE" backup "$prefix" "${backup_env[@]}" >/dev/null
  s3_ls "s3://${BUCKET}/${prefix}/" | grep -qE 'PRE [0-9]{8}_[0-9]{6}/' ||
    fail "sqlite: no run folder uploaded"
  pass "sqlite: backup uploaded a run folder while the application was writing"

  info "sqlite: fetch, and check the copy is one whole snapshot"
  backup_image "$SQLITE_IMAGE" fetch "$prefix" -e FETCH_DECOMPRESS=true -v "${SQLITE_FETCH}:/restore" >/dev/null
  fetched="$(docker run --rm -v "${SQLITE_FETCH}:/data" --entrypoint sh "$SQLITE_IMAGE" -c '
    f=$(find /data -name "*.sqlite" -print -quit)
    [ "$(sqlite3 "$f" "PRAGMA integrity_check")" = ok ] || exit 1
    sqlite3 "$f" "SELECT count(*) FROM t"')" || fail "sqlite: the fetched copy fails integrity_check"
  ((fetched > 0 && fetched % 50 == 0)) ||
    fail "sqlite: expected a whole number of 50-row transactions, got ${fetched} rows"
  pass "sqlite: the copy passes integrity_check and holds ${fetched} rows, no torn transaction"

  docker wait "${PROJECT}-sqlite-writer" >/dev/null
  docker rm "${PROJECT}-sqlite-writer" >/dev/null
  # The writer opens and closes a connection per transaction, so the -shm comes
  # and goes: whatever the backup created must belong to the application.
  [[ -z "$(docker run --rm -v "${SQLITE_DATA}:/data" --entrypoint find "$SQLITE_IMAGE" /data ! -user 1001 ! -name lost+found)" ]] ||
    fail "sqlite: the backup left files owned by its own user beside the database"
  pass "sqlite: the backup created nothing beside the database"

  info "sqlite: the application changes the data and dies, leaving its WAL"
  sqlite_as 1001:1000 "$SQLITE_DATA" /data/app.db "DELETE FROM t;" >/dev/null
  docker run -d --name "${PROJECT}-sqlite-writer" --user 1001:1000 -v "${SQLITE_DATA}:/data" \
    --entrypoint sh "$SQLITE_IMAGE" -c \
    "sqlite3 /data/app.db 'PRAGMA wal_autocheckpoint=0;' \"INSERT INTO t(v) VALUES ('stale');\" '.shell sleep 60'" >/dev/null
  sleep 2
  docker kill "${PROJECT}-sqlite-writer" >/dev/null
  docker rm "${PROJECT}-sqlite-writer" >/dev/null
  docker run --rm -v "${SQLITE_DATA}:/data" --entrypoint sh "$SQLITE_IMAGE" -c '[ -s /data/app.db-wal ]' ||
    fail "sqlite: setup did not leave a WAL behind"

  info "sqlite: restore, as root so the file keeps its owner"
  backup_image "$SQLITE_IMAGE" restore "$prefix" "${env[@]}" >/dev/null

  rows="$(sqlite_as 1001:1000 "$SQLITE_DATA" /data/app.db 'SELECT count(*) FROM t')"
  [[ "$rows" == "$fetched" ]] || fail "sqlite: expected ${fetched} rows after restore, got '${rows}'"
  pass "sqlite: the restored rows are the backup's; the leftover WAL did not reach them"

  docker run --rm -v "${SQLITE_DATA}:/data" --entrypoint sh "$SQLITE_IMAGE" -c \
    'ls /data/app.db.pre-restore-*-wal >/dev/null 2>&1' || fail "sqlite: the old WAL was not kept aside"
  owner="$(docker run --rm -v "${SQLITE_DATA}:/data" --entrypoint stat "$SQLITE_IMAGE" -c %u /data/app.db)"
  [[ "$owner" == "1001" ]] || fail "sqlite: restored file owned by ${owner}, not the application"
  sqlite_as 1001:1000 "$SQLITE_DATA" /data/app.db "INSERT INTO t(v) VALUES ('after');" >/dev/null ||
    fail "sqlite: the application cannot write the restored database"
  pass "sqlite: the old database and WAL are kept, and the application owns and writes the new one"
}

main() {
  local backends=("${@:-}")
  [[ -n "${backends[0]:-}" ]] || backends=(postgresql postgresql_owner completeness mongodb mongodb_oplog redis vault sqlite schedule notify upload_failure)

  start_stack "${backends[@]}"
  local b
  for b in "${backends[@]}"; do
    "test_${b}"
  done
  printf '\n\033[0;32mAll integration tests passed\033[0m\n'
}

main "$@"
