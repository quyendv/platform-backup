#!/usr/bin/env bash
# End-to-end: seed a real target, back it up to a real MinIO, destroy the data,
# restore it, and assert the data came back.
#
# Usage: test/integration/run.sh [backend ...]   (default: postgresql mongodb vault schedule notify)
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
    postgresql | schedule) printf 'postgres' ;;
    notify) printf 'postgres notifysink' ;;
    mongodb) printf 'mongo' ;;
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

  info "postgresql: backup"
  backup_image "$image" backup "$prefix" "${env[@]}" >/dev/null
  s3_ls "s3://${BUCKET}/${prefix}/" | grep -qE 'PRE [0-9]{8}_[0-9]{6}/' ||
    fail "postgresql: no run folder uploaded"
  pass "postgresql: backup uploaded a run folder"

  info "postgresql: destroying the data"
  psql_target -c "DROP TABLE widgets;"

  info "postgresql: restore"
  backup_image "$image" restore "$prefix" "${env[@]}" >/dev/null

  local rows
  rows="$(psql_target -c "SELECT count(*) FROM widgets;")"
  [[ "$rows" == "3" ]] || fail "postgresql: expected 3 rows after restore, got '${rows}'"
  local name
  name="$(psql_target -c "SELECT name FROM widgets WHERE id=2;")"
  [[ "$name" == "beta" ]] || fail "postgresql: expected 'beta', got '${name}'"
  pass "postgresql: data survived backup -> restore"

  info "postgresql: fetch"
  backup_image "$image" fetch "$prefix" "${env[@]}" >/dev/null
  pass "postgresql: fetch verified the checksum"
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

main() {
  local backends=("${@:-}")
  [[ -n "${backends[0]:-}" ]] || backends=(postgresql mongodb vault schedule notify)

  start_stack "${backends[@]}"
  local b
  for b in "${backends[@]}"; do
    "test_${b}"
  done
  printf '\n\033[0;32mAll integration tests passed\033[0m\n'
}

main "$@"
