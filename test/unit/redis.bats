#!/usr/bin/env bats
#
# The redis adapter. MIGRATE needs the target's host, port, password and db as
# separate arguments, so the single REDIS_URL has to be taken apart — and a
# mistake there restores into the wrong database or silently drops the password.

# Every @test body is its own subshell, which is exactly where these variables
# are meant to live; shellcheck reads that as an accidental scope.
# shellcheck disable=SC2030,SC2031
bats_require_minimum_version 1.5.0

setup() {
  set -euo pipefail
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  source "$REPO_ROOT/lib/log.sh"
  source "$REPO_ROOT/lib/env.sh"
  source "$REPO_ROOT/backends/redis/backend.sh"

  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  PATH="$STUB_BIN:$PATH"
  RUN_ID=20260101_000000
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK"
}

part() { REDIS_URL="$1" _redis_url_part "$2"; }

# --- URL parsing -------------------------------------------------------------

@test "a bare host and port" {
  [ "$(part redis://cache.internal:6379 host)" = "cache.internal" ]
  [ "$(part redis://cache.internal:6379 port)" = "6379" ]
  [ "$(part redis://cache.internal:6379 password)" = "" ]
  [ "$(part redis://cache.internal:6379 db)" = "0" ]
}

@test "the port defaults to 6379 and the database to 0" {
  [ "$(part redis://cache.internal host)" = "cache.internal" ]
  [ "$(part redis://cache.internal port)" = "6379" ]
  [ "$(part redis://cache.internal db)" = "0" ]
}

@test "a password with no username" {
  [ "$(part redis://:s3cret@cache:6379 password)" = "s3cret" ]
  [ "$(part redis://:s3cret@cache:6379 host)" = "cache" ]
}

@test "a username and password" {
  [ "$(part redis://alice:s3cret@cache:6379 password)" = "s3cret" ]
  [ "$(part redis://alice:s3cret@cache:6379 host)" = "cache" ]
}

@test "a database index is read from the path" {
  [ "$(part redis://cache:6379/3 db)" = "3" ]
  [ "$(part redis://:pw@cache:6379/11 db)" = "11" ]
  [ "$(part redis://:pw@cache:6379/11 host)" = "cache" ]
}

@test "a password containing an at sign is taken from the last one" {
  # user:p@ss@host is ambiguous; the host is whatever follows the final @.
  [ "$(part 'redis://:p@ss@cache:6379' host)" = "cache" ]
  [ "$(part 'redis://:p@ss@cache:6379' password)" = "p@ss" ]
}

@test "rediss is recognised as TLS" {
  [ "$(part rediss://cache:6379 host)" = "cache" ]
  REDIS_URL=rediss://cache:6379 run _redis_url_is_tls
  [ "$status" -eq 0 ]

  REDIS_URL=redis://cache:6379 run _redis_url_is_tls
  [ "$status" -ne 0 ]
}

@test "a URL with no scheme is rejected rather than guessed at" {
  run part cache:6379 host
  [ "$status" -ne 0 ]
}

# --- stubs -------------------------------------------------------------------

stub_redis_cli() {
  # $1 = exit code, $2 = INFO cluster reply
  cat >"$STUB_BIN/redis-cli" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  [[ "\$a" == "ping" || "\$a" == "PING" ]] && { echo PONG; exit 0; }
  [[ "\$a" == "cluster" ]] && { echo "${2:-cluster_enabled:0}"; exit 0; }
done
# --rdb writes its file so the caller can carry on
prev=""
for a in "\$@"; do
  [[ "\$prev" == "--rdb" ]] && printf 'REDIS0011stub' > "\$a"
  prev="\$a"
done
exit ${1:-0}
STUB
  chmod +x "$STUB_BIN/redis-cli"
}

# --- validation --------------------------------------------------------------

@test "a cluster is refused rather than backed up in part" {
  # One endpoint sees only its own shard: backing it up silently captures a
  # fraction of the keyspace.
  stub_redis_cli 0 'cluster_enabled:1'
  export REDIS_URL=redis://cache:6379

  run backend_validate

  [ "$status" -ne 0 ]
  [[ "$output" == *"cluster"* ]]
}

@test "a standalone server passes validation" {
  stub_redis_cli 0 'cluster_enabled:0'
  export REDIS_URL=redis://cache:6379

  run backend_validate

  [ "$status" -eq 0 ]
}

@test "an unreachable server is refused" {
  cat >"$STUB_BIN/redis-cli" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$STUB_BIN/redis-cli"
  export REDIS_URL=redis://cache:6379

  run backend_validate

  [ "$status" -ne 0 ]
}

@test "REDIS_URL is required" {
  run backend_validate

  [ "$status" -ne 0 ]
  [[ "$output" == *"REDIS_URL"* ]]
}

# --- dump --------------------------------------------------------------------

@test "dump fails when redis-cli fails" {
  # The adapter must check its own tool: backend_dump ends by echoing a
  # filename, so its exit status reflects that echo, not the dump.
  stub_redis_cli 1 'cluster_enabled:0'
  export REDIS_URL=redis://cache:6379

  run backend_dump "$WORK"

  [ "$status" -ne 0 ]
  [[ "$output" == *"--rdb"* ]]
}

@test "dump echoes only the artifact name, and compresses it" {
  stub_redis_cli 0 'cluster_enabled:0'
  export REDIS_URL=redis://cache:6379

  run --separate-stderr backend_dump "$WORK"

  [ "$status" -eq 0 ]
  [ "$output" = "redis-20260101_000000.rdb.gz" ]
  [ -f "$WORK/redis-20260101_000000.rdb.gz" ]
  # The uncompressed intermediate must not be left behind for upload.
  [ ! -f "$WORK/dump.rdb" ]
  run gzip -t "$WORK/redis-20260101_000000.rdb.gz"
  [ "$status" -eq 0 ]
}

# --- hooks and staging -------------------------------------------------------
# Proving that a staged RDB actually parses needs a real redis-server, which
# only the image has; that lives in the integration suite. What is worth
# checking here is that the hooks exist — otherwise every "run backend_verify
# ... expect failure" below passes because the function is missing.

@test "the adapter defines every hook the driver calls" {
  local hook
  for hook in backend_name backend_caps backend_validate backend_dump \
    backend_verify backend_restore; do
    declare -F "$hook" >/dev/null || {
      echo "missing hook: $hook" >&2
      false
    }
  done
}

@test "verify rejects something that is not a gzip" {
  printf 'not gzip' >"$WORK/bad.rdb.gz"

  run backend_verify "$WORK/bad.rdb.gz"

  [ "$status" -ne 0 ]
}

@test "staging does not listen on the default Redis port" {
  # Staging runs inside the backup container, but a stray 6379 would make a
  # mistake here talk to whatever else happens to be listening.
  run grep -oE 'REDIS_STAGE_PORT:=[0-9]+' "$REPO_ROOT/backends/redis/backend.sh"

  [ "$status" -eq 0 ]
  [[ "$output" != *":=6379" ]]
}

@test "restore refuses a TLS target it cannot reach with MIGRATE" {
  # MIGRATE has no TLS option, so a rediss:// target cannot be restored this
  # way. Refusing beats restoring part of the keyspace.
  export REDIS_URL=rediss://cache:6379
  printf 'x' | gzip -c >"$WORK/a.rdb.gz"

  run backend_restore "$WORK/a.rdb.gz"

  [ "$status" -ne 0 ]
  [[ "$output" == *"TLS"* ]]
}

@test "a disabled FLUSHDB is reported as such, not as a mystery" {
  # The Bitnami chart renames FLUSHDB and FLUSHALL to "" by default, so
  # RESTORE_FLUSH fails there with "unknown command" and no hint why.
  cat >"$STUB_BIN/redis-cli" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
  [[ "$a" == "ping" ]] && { echo PONG; exit 0; }
  [[ "$a" == "flushdb" ]] && { echo "ERR unknown command 'flushdb'" >&2; exit 1; }
done
exit 0
STUB
  chmod +x "$STUB_BIN/redis-cli"
  cat >"$STUB_BIN/redis-server" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$STUB_BIN/redis-server"
  export REDIS_URL=redis://cache:6379 RESTORE_FLUSH=true BACKUP_DIR="$BATS_TEST_TMPDIR"
  printf 'x' | gzip -c >"$WORK/a.rdb.gz"

  run backend_restore "$WORK/a.rdb.gz"

  [ "$status" -ne 0 ]
  [[ "$output" == *"disabled"* ]]
}
