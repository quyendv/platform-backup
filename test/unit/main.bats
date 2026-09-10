#!/usr/bin/env bats
#
# The driver: mode dispatch, capability gating, and the backup pipeline.
# A fake backend adapter stands in for a real database.

setup() {
  set -euo pipefail
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  source "$REPO_ROOT/test/unit/helpers/stub_aws.bash"
  stub_aws_init

  BACKUP_DIR="$BATS_TEST_TMPDIR/backup"
  RESTORE_DIR="$BATS_TEST_TMPDIR/restore"
  S3_BUCKET=""
  S3_PREFIX="backups/fake"
  KEEP_LOCAL=3
  KEEP_REMOTE=30
  DRY_RUN=false
  RESTORE_TIMESTAMP=""
  RESTORED_FROM="$BATS_TEST_TMPDIR/restored-from"

  source "$REPO_ROOT/lib/main.sh"
  fake_backend
}

# A backend that can do everything, writing a predictable artifact.
fake_backend() {
  backend_name() { printf 'fake'; }
  backend_caps() { printf 'fetch restore'; }
  backend_validate() { :; }
  backend_dump() {
    local dir="$1"
    printf 'contents' >"$dir/fake-${RUN_ID}.dump"
    printf 'fake-%s.dump' "$RUN_ID"
  }
  backend_restore() { printf '%s' "$1" >"$RESTORED_FROM"; }
}

# --- mode dispatch -----------------------------------------------------------

@test "rejects an unknown mode" {
  MODE=sideways run main

  [ "$status" -ne 0 ]
  [[ "$output" == *"sideways"* ]]
}

@test "backup is the default mode" {
  MODE='' run main

  [ "$status" -eq 0 ]
}

# --- backup ------------------------------------------------------------------

@test "backup writes the artifact into a timestamped run directory" {
  MODE=backup run main
  [ "$status" -eq 0 ]

  run find "$BACKUP_DIR" -name 'fake-*.dump'
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" =~ /[0-9]{8}_[0-9]{6}/fake-[0-9]{8}_[0-9]{6}\.dump$ ]]
}

@test "backup writes a checksum sidecar beside the artifact" {
  MODE=backup main

  run find "$BACKUP_DIR" -name '*.dump.sha256'
  [ "${#lines[@]}" -eq 1 ]
}

@test "backup fails when the backend produces an empty artifact" {
  backend_dump() {
    : >"$1/fake-${RUN_ID}.dump"
    printf 'fake-%s.dump' "$RUN_ID"
  }

  MODE=backup run main

  [ "$status" -ne 0 ]
  [[ "$output" == *"empty"* ]]
}

@test "backup skips the object store when no bucket is configured" {
  MODE=backup S3_BUCKET='' main

  run aws_calls
  [ "$output" = "" ]
}

@test "backup uploads when a bucket is configured" {
  MODE=backup S3_BUCKET=my-bucket main

  run aws_calls
  [[ "$output" == *"s3://my-bucket/backups/fake/"* ]]
}

@test "backup prunes local runs beyond KEEP_LOCAL" {
  mkdir -p "$BACKUP_DIR"/2026010{1,2,3}_000000

  MODE=backup KEEP_LOCAL=2 main

  run find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d
  [ "${#lines[@]}" -eq 2 ]
}

# --- capability gating -------------------------------------------------------

@test "restore is refused when the backend does not support it" {
  backend_caps() { printf 'fetch'; }
  backend_restore_hint() { printf 'run etcdctl on the host\n'; }

  MODE=restore S3_BUCKET=my-bucket run main

  [ "$status" -ne 0 ]
  [[ "$output" == *"does not support"* ]]
}

@test "the refusal prints the backend's own hint" {
  backend_caps() { printf 'fetch'; }
  backend_restore_hint() { printf 'run etcdctl on the host\n'; }

  MODE=restore S3_BUCKET=my-bucket run main

  [[ "$output" == *"run etcdctl on the host"* ]]
}

@test "a backend without a hint is still refused cleanly" {
  backend_caps() { printf 'fetch'; }

  MODE=restore S3_BUCKET=my-bucket run main

  [ "$status" -ne 0 ]
}

# --- fetch and restore need an object store ----------------------------------

@test "fetch fails when no bucket is configured" {
  MODE=fetch S3_BUCKET='' run main

  [ "$status" -ne 0 ]
  [[ "$output" == *"S3_BUCKET"* ]]
}

# --- fetch happy path --------------------------------------------------------
# Guards the command-substitution contract: log output must not leak into the
# value _fetch_into returns.

@test "fetch downloads the newest run and reports the real artifact path" {
  stub_aws_stdout "                           PRE 20260101_000000/"
  # The stub cannot copy files, so stage what the download would have produced.
  mkdir -p "$RESTORE_DIR/20260101_000000"
  printf 'payload' >"$RESTORE_DIR/20260101_000000/fake.dump"
  (cd "$RESTORE_DIR/20260101_000000" && sha256sum fake.dump >fake.dump.sha256)

  MODE=fetch S3_BUCKET=my-bucket run main

  [ "$status" -eq 0 ]
  [[ "$output" == *"$RESTORE_DIR/20260101_000000/fake.dump"* ]]
  [[ "$output" != *"[INFO"*"$RESTORE_DIR/20260101_000000/fake.dump"*"[INFO"* ]]
}

@test "restore hands the backend a bare artifact path, not log output" {
  stub_aws_stdout "                           PRE 20260101_000000/"
  mkdir -p "$RESTORE_DIR/20260101_000000"
  printf 'payload' >"$RESTORE_DIR/20260101_000000/fake.dump"
  (cd "$RESTORE_DIR/20260101_000000" && sha256sum fake.dump >fake.dump.sha256)

  MODE=restore S3_BUCKET=my-bucket main

  run cat "$RESTORED_FROM"
  [ "$output" = "$RESTORE_DIR/20260101_000000/fake.dump" ]
}

# --- validation order --------------------------------------------------------

@test "an unknown mode is reported before backend env validation" {
  # Otherwise a typo in MODE hides behind whatever the backend happens to
  # require: 'MODE=sideways' on an unconfigured Vault complained about
  # VAULT_ADDR, which sends you looking in the wrong place.
  backend_validate() { die "VAULT_ADDR is missing"; }

  MODE=sideways run main

  [ "$status" -ne 0 ]
  [[ "$output" == *"sideways"* ]]
  [[ "$output" != *"VAULT_ADDR"* ]]
}
