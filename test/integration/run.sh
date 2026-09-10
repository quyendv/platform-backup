#!/usr/bin/env bash
# End-to-end: seed a real target, back it up to a real MinIO, destroy the data,
# restore it, and assert the data came back.
#
# Usage: test/integration/run.sh [backend ...]   (default: postgresql mongodb)
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

start_stack() {
  info "Starting MinIO and targets"
  "${COMPOSE[@]}" up -d --wait
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

main() {
  local backends=("${@:-}")
  [[ -n "${backends[0]:-}" ]] || backends=(postgresql mongodb)

  start_stack
  local b
  for b in "${backends[@]}"; do
    "test_${b}"
  done
  printf '\n\033[0;32mAll integration tests passed\033[0m\n'
}

main "$@"
