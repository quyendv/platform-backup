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

# --- the staging server ------------------------------------------------------
# Restore loads the RDB into a throwaway redis-server. These stubs stand in for
# it: one that dies at once (a corrupt or too-new RDB), one that stays up.

# A server that stays up until killed, recording its arguments and its PID.
stub_live_server() {
  cat >"$STUB_BIN/redis-server" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$BATS_TEST_TMPDIR/server.args"
printf '%s' "\$\$" >"$BATS_TEST_TMPDIR/server.pid"
# Let go of bats' output pipes, so a server the adapter fails to stop makes
# the test fail rather than hang.
exec sleep 300 >/dev/null 2>&1 3>&-
STUB
  chmod +x "$STUB_BIN/redis-server"
}

# A redis-cli that answers LOADING to the first $1 pings, then PONG.
# $1 = -1 means it never finishes loading.
stub_loading_cli() {
  cat >"$STUB_BIN/redis-cli" <<STUB
#!/usr/bin/env bash
counter="$BATS_TEST_TMPDIR/pings"
for a in "\$@"; do
  if [[ "\$a" == "ping" ]]; then
    n=\$((\$(cat "\$counter" 2>/dev/null || echo 0) + 1))
    printf '%s' "\$n" >"\$counter"
    if (( ${1} < 0 || n <= ${1} )); then
      echo "LOADING Redis is loading the dataset in memory"
      exit 1
    fi
    echo PONG
    exit 0
  fi
  [[ "\$a" == "persistence" ]] && { printf 'loading:1\r\nloading_loaded_perc:42.00\r\n'; exit 0; }
done
exit 0
STUB
  chmod +x "$STUB_BIN/redis-cli"
}

# Fails while PID is still running. `! kill -0` would not: bats ignores `!`.
assert_gone() {
  run kill -0 "$1"
  [ "$status" -ne 0 ]
}

stage_archive() {
  printf 'REDIS0011stub' | gzip -c >"$WORK/a.rdb.gz"
}

@test "staging fails fast when the server exits, instead of waiting out the timeout" {
  # A corrupt or too-new RDB makes redis-server exit at once. That must not be
  # mistaken for a slow load and waited on for an hour.
  cat >"$STUB_BIN/redis-server" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$STUB_BIN/redis-server"
  stub_loading_cli -1
  stage_archive
  export REDIS_STAGE_TIMEOUT=30

  run _redis_stage "$WORK/a.rdb.gz" "$WORK/stage"

  [ "$status" -ne 0 ]
  [[ "$output" == *"exited"* ]]
  [ ! -e "$WORK/stage" ]
}

@test "staging keeps waiting while the server is still loading" {
  # Loading answers LOADING, not PONG. The old loop gave up after 40 pings,
  # so any dataset that took more than 10 s to load failed as "corrupt".
  stub_live_server
  stub_loading_cli 60
  stage_archive
  export REDIS_STAGE_TIMEOUT=30 _REDIS_STAGE_POLL=0

  _redis_stage "$WORK/a.rdb.gz" "$WORK/stage"
  local rc=$? pid
  pid="$(cat "$BATS_TEST_TMPDIR/server.pid")"
  _redis_stage_stop

  [ "$rc" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/pings")" -eq 61 ]
  assert_gone "$pid"
  [ ! -e "$WORK/stage" ]
}

@test "staging gives up at REDIS_STAGE_TIMEOUT and leaves nothing running" {
  # A server left behind holds the dataset in memory and, in SCHEDULE mode,
  # answers the next run's checks in place of the server that run started.
  stub_live_server
  stub_loading_cli -1
  stage_archive
  export REDIS_STAGE_TIMEOUT=1

  run _redis_stage "$WORK/a.rdb.gz" "$WORK/stage"

  [ "$status" -ne 0 ]
  [[ "$output" == *"REDIS_STAGE_TIMEOUT"* ]]
  assert_gone "$(cat "$BATS_TEST_TMPDIR/server.pid")"
  [ ! -e "$WORK/stage" ]
}

@test "staging listens on a socket in its own directory, never on a TCP port" {
  # A TCP port can be held by something else — including a staging server
  # left over from an earlier run — which then answers in its place.
  stub_live_server
  stub_loading_cli 0
  stage_archive

  _redis_stage "$WORK/a.rdb.gz" "$WORK/stage"
  _redis_stage_stop

  local args
  args="$(cat "$BATS_TEST_TMPDIR/server.args")"
  [[ "$args" == *"--port 0"* ]]
  [[ "$args" == *"--unixsocket $WORK/stage/"* ]]
  [[ "$args" != *"--daemonize yes"* ]]
}

@test "staging rejects an artifact it cannot decompress, leaving no directory" {
  printf 'not gzip' >"$WORK/bad.rdb.gz"

  run _redis_stage "$WORK/bad.rdb.gz" "$WORK/stage"

  [ "$status" -ne 0 ]
  [ ! -e "$WORK/stage" ]
}

@test "REDIS_STAGE_TIMEOUT must be a positive integer" {
  export REDIS_URL=redis://cache:6379 REDIS_STAGE_TIMEOUT=10m
  stub_redis_cli 0 'cluster_enabled:0'

  run backend_validate

  [ "$status" -ne 0 ]
  [[ "$output" == *"REDIS_STAGE_TIMEOUT"* ]]
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
  stub_live_server
  export REDIS_URL=redis://cache:6379 RESTORE_FLUSH=true BACKUP_DIR="$BATS_TEST_TMPDIR"
  printf 'x' | gzip -c >"$WORK/a.rdb.gz"

  run backend_restore "$WORK/a.rdb.gz"

  [ "$status" -ne 0 ]
  [[ "$output" == *"disabled"* ]]
  # A failed restore stops its staging server and removes its directory.
  assert_gone "$(cat "$BATS_TEST_TMPDIR/server.pid")"
  run find "$BATS_TEST_TMPDIR" -maxdepth 1 -name '.restore-*'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
