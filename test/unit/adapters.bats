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
