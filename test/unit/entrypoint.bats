#!/usr/bin/env bats
#
# The container entrypoint: how MODE and SCHEDULE combine.

setup() {
  set -euo pipefail
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

  # An image-shaped APP_DIR: lib/ plus one backend.sh, exactly as the Dockerfiles
  # lay it out.
  APP_DIR="$BATS_TEST_TMPDIR/app"
  mkdir -p "$APP_DIR"
  cp -r "$REPO_ROOT/lib" "$APP_DIR/lib"
  cp "$REPO_ROOT/entrypoint.sh" "$APP_DIR/entrypoint.sh"
  cat >"$APP_DIR/backend.sh" <<'BACKEND'
backend_name() { printf 'fake'; }
backend_caps() { printf 'fetch restore'; }
backend_validate() { :; }
backend_dump() {
  printf 'x' > "$1/fake-${RUN_ID}.dump"
  printf 'fake-%s.dump' "$RUN_ID"
}
BACKEND

  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  cat >"$STUB_BIN/supercronic" <<STUB
#!/usr/bin/env bash
printf 'supercronic %s\n' "\$*" > "$BATS_TEST_TMPDIR/supercronic-call"
cat "\${@: -1}" > "$BATS_TEST_TMPDIR/crontab-content"
STUB
  chmod +x "$STUB_BIN/supercronic"

  export PATH="$STUB_BIN:$PATH"
  export APP_DIR BACKUP_DIR="$BATS_TEST_TMPDIR/backup" S3_BUCKET=''
}

count_dumps() {
  find "$BACKUP_DIR" -name '*.dump' 2>/dev/null | wc -l
}

run_entrypoint() {
  run env APP_DIR="$APP_DIR" BACKUP_DIR="$BACKUP_DIR" S3_BUCKET='' "$@" \
    bash "$APP_DIR/entrypoint.sh"
}

@test "with no SCHEDULE it runs one backup and exits" {
  run_entrypoint MODE=backup

  [ "$status" -eq 0 ]
  [ ! -f "$BATS_TEST_TMPDIR/supercronic-call" ]
  [ "$(count_dumps)" -eq 1 ]
}

@test "with SCHEDULE set it hands over to supercronic" {
  run_entrypoint MODE=backup SCHEDULE='0 */4 * * *'

  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/supercronic-call" ]
}

@test "the generated crontab carries the schedule and re-invokes the entrypoint" {
  run_entrypoint MODE=backup SCHEDULE='0 */4 * * *'

  run cat "$BATS_TEST_TMPDIR/crontab-content"
  [[ "$output" == "0 */4 * * *"* ]]
  [[ "$output" == *"entrypoint.sh run"* ]]
}

@test "MODE=restore ignores SCHEDULE and stays one-shot" {
  run_entrypoint MODE=restore SCHEDULE='0 */4 * * *'

  # It reached the restore path (and refused, since no bucket is configured)
  # rather than handing over to the scheduler.
  [ "$status" -ne 0 ]
  [[ "$output" == *"S3_BUCKET"* ]]
  [ ! -f "$BATS_TEST_TMPDIR/supercronic-call" ]
}

@test "MODE is case-insensitive" {
  run_entrypoint MODE=BACKUP

  [ "$status" -eq 0 ]
  [ "$(count_dumps)" -eq 1 ]
}

@test "the run subcommand performs a single backup without consulting SCHEDULE" {
  run env APP_DIR="$APP_DIR" BACKUP_DIR="$BACKUP_DIR" S3_BUCKET='' \
    SCHEDULE='0 */4 * * *' bash "$APP_DIR/entrypoint.sh" run

  [ "$status" -eq 0 ]
  [ ! -f "$BATS_TEST_TMPDIR/supercronic-call" ]
  [ "$(count_dumps)" -eq 1 ]
}
