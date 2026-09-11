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
    # Comfortably over MIN_ARTIFACT_BYTES; the size floor has its own tests.
    head -c 2048 /dev/zero | tr '\0' 'x' >"$dir/fake-${RUN_ID}.dump"
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

@test "backup rejects an artifact that is implausibly small" {
  backend_dump() {
    : >"$1/fake-${RUN_ID}.dump"
    printf 'fake-%s.dump' "$RUN_ID"
  }

  MODE=backup run main

  [ "$status" -ne 0 ]
  [[ "$output" == *"implausibly small"* ]]
}

@test "the size floor is configurable" {
  backend_dump() {
    head -c 100 /dev/zero | tr '\0' 'x' >"$1/fake-${RUN_ID}.dump"
    printf 'fake-%s.dump' "$RUN_ID"
  }

  MODE=backup MIN_ARTIFACT_BYTES=50 run main
  [ "$status" -eq 0 ]
}

@test "two runs in the same second do not corrupt a run folder" {
  # A frozen run-id clock makes the collision certain instead of occasional.
  stub_fixed_run_id 20260101_000000

  MODE=backup main
  local existing
  existing="$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d)"

  MODE=backup run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]

  # The original run is untouched, with nothing nested inside it.
  [ "$(find "$existing" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 0 ]
  [ "$(find "$existing" -name '*.dump' | wc -l)" -eq 1 ]
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

# --- failed runs must not occupy retention slots ------------------------------
# A failed run used to leave an empty YYYYMMDD_HHMMSS directory behind. Because
# prune keeps the newest N by name, a run of failures evicted every good backup.

@test "a failed dump leaves no run directory behind" {
  backend_dump() { return 1; }

  MODE=backup run main
  [ "$status" -ne 0 ]

  run find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d
  [ "$output" = "" ]
}

@test "repeated failures never evict good backups" {
  # Distinct run ids need distinct seconds; failures create no directory, so
  # only the successful runs have to be spaced out.
  MODE=backup KEEP_LOCAL=3 main
  sleep 1
  MODE=backup KEEP_LOCAL=3 main
  sleep 1

  backend_dump() { return 1; }
  for _ in 1 2 3 4; do
    MODE=backup KEEP_LOCAL=3 run main
  done

  backend_dump() {
    head -c 2048 /dev/zero | tr '\0' 'x' >"$1/fake-${RUN_ID}.dump"
    printf 'fake-%s.dump' "$RUN_ID"
  }
  MODE=backup KEEP_LOCAL=3 main

  # Two good backups predate the failures; all three must survive.
  [ "$(find "$BACKUP_DIR" -name '*.dump' | wc -l)" -eq 3 ]
}

@test "an artifact the backend leaves half-written is not promoted" {
  backend_dump() {
    printf 'partial' >"$1/fake-${RUN_ID}.dump"
    return 1
  }

  MODE=backup run main
  [ "$status" -ne 0 ]

  run find "$BACKUP_DIR" -name '*.dump'
  [ "$output" = "" ]
}

@test "a crashed run's staging directory is not mistaken for a backup" {
  mkdir -p "$BACKUP_DIR/.staging-20260101_000000"
  echo junk >"$BACKUP_DIR/.staging-20260101_000000/leftover.dump"

  MODE=backup KEEP_LOCAL=3 main

  [ ! -d "$BACKUP_DIR/.staging-20260101_000000" ]
  [ "$(find "$BACKUP_DIR" -name '*.dump' | wc -l)" -eq 1 ]
}

@test "fetch picks the artifact by its checksum, not by directory order" {
  # Choosing "the first file that is not a .sha256" depends on readdir order,
  # which differs between machines: this passed locally and picked a padding
  # file on CI.
  stub_aws_stdout "                           PRE 20260101_000000/"
  mkdir -p "$RESTORE_DIR/20260101_000000"
  local i
  for i in $(seq 1 200); do : >"$RESTORE_DIR/20260101_000000/pad-$i.bin"; done
  printf 'payload' >"$RESTORE_DIR/20260101_000000/real.dump"
  (cd "$RESTORE_DIR/20260101_000000" && sha256sum real.dump >real.dump.sha256)

  MODE=fetch S3_BUCKET=my-bucket run main

  [ "$status" -eq 0 ]
  [[ "$output" == *"real.dump"* ]]
  [[ "$output" != *"pad-"* ]]
}

@test "fetch refuses a run whose artifact is missing" {
  # Half an upload: checksum there, artifact not.
  stub_aws_stdout "                           PRE 20260101_000000/"
  mkdir -p "$RESTORE_DIR/20260101_000000"
  printf 'deadbeef  real.dump\n' >"$RESTORE_DIR/20260101_000000/real.dump.sha256"

  MODE=fetch S3_BUCKET=my-bucket run main

  [ "$status" -ne 0 ]
  [[ "$output" == *"incomplete"* ]]
}

@test "an invalid DRY_RUN is rejected rather than read as false" {
  MODE=backup DRY_RUN=ture run main

  [ "$status" -ne 0 ]
  [[ "$output" == *"DRY_RUN"* ]]
}

# --- artifact integrity ------------------------------------------------------
# A size floor cannot tell an empty database from a truncated dump: both are
# small. A real pg_dump of an empty database gzips to ~405 bytes, so a floor
# high enough to catch corruption also rejects legitimate backups. The floor
# only catches "the tool produced nothing"; integrity is the backend's job.

@test "the backend's own verification runs before promotion" {
  VERIFIED="$BATS_TEST_TMPDIR/verified"
  backend_verify() { printf '%s' "$1" >"$VERIFIED"; }

  MODE=backup main

  [ -f "$VERIFIED" ]
  [[ "$(cat "$VERIFIED")" == *".dump" ]]
}

@test "a run failing verification is discarded, not promoted" {
  backend_verify() { return 1; }

  MODE=backup run main

  [ "$status" -ne 0 ]
  [[ "$output" == *"verification"* ]]
  run find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d
  [ "$output" = "" ]
}

@test "a backend without a verify hook still works" {
  unset -f backend_verify 2>/dev/null || true

  MODE=backup run main

  [ "$status" -eq 0 ]
}

@test "an artifact of a few bytes is still rejected" {
  backend_dump() {
    printf 'x' >"$1/fake-${RUN_ID}.dump"
    printf 'fake-%s.dump' "$RUN_ID"
  }

  MODE=backup run main
  [ "$status" -ne 0 ]
}

# --- state and notification wiring -------------------------------------------

@test "a successful run records success" {
  MODE=backup main

  run jq -r '.outcome, .backend' "$BACKUP_DIR/.last-run.json"
  [ "${lines[0]}" = "success" ]
  [ "${lines[1]}" = "fake" ]
}

@test "a failed run records the failure and the message" {
  backend_dump() { return 1; }

  MODE=backup run main
  [ "$status" -ne 0 ]

  run jq -r '.outcome, .error' "$BACKUP_DIR/.last-run.json"
  [ "${lines[0]}" = "failure" ]
  [[ "${lines[1]}" == *"dump failed"* ]]
}

@test "the recorded run id matches the promoted run" {
  MODE=backup main

  local recorded
  recorded="$(jq -r '.run_id' "$BACKUP_DIR/.last-run.json")"
  [ -d "$BACKUP_DIR/$recorded" ]
}

@test "state is recorded for fetch and restore too, not just backup" {
  stub_aws_stdout "                           PRE 20260101_000000/"
  mkdir -p "$RESTORE_DIR/20260101_000000"
  printf 'payload' >"$RESTORE_DIR/20260101_000000/fake.dump"
  (cd "$RESTORE_DIR/20260101_000000" && sha256sum fake.dump >fake.dump.sha256)

  MODE=fetch S3_BUCKET=my-bucket main

  run jq -r '.outcome' "$BACKUP_DIR/.last-run.json"
  [ "$output" = "success" ]
}

@test "a notification failure does not fail the backup" {
  NOTIFY_ON=always NOTIFY_WEBHOOK_URL=http://127.0.0.1:1/nope \
    MODE=backup run main

  [ "$status" -eq 0 ]
}
