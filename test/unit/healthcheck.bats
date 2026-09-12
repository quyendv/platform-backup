#!/usr/bin/env bats
#
# The healthcheck turns "the last backup failed" into something docker ps,
# autoheal and orchestrators can see. Without it a container whose every run
# fails still reports Up, with exit code 0.

setup() {
  set -euo pipefail
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  BACKUP_DIR="$BATS_TEST_TMPDIR/backup"
  mkdir -p "$BACKUP_DIR"
  export BACKUP_DIR
  HC="$REPO_ROOT/healthcheck.sh"
}

write_state() {
  jq -n --arg o "$1" --arg at "$2" \
    '{schema: 1, outcome: $o, finished_at: $at}' >"$BACKUP_DIR/.last-run.json"
}

ago() { date -u -d "$1" '+%Y-%m-%dT%H:%M:%SZ'; }

@test "healthy after a recent success" {
  write_state success "$(ago '-1 minute')"

  run bash "$HC"

  [ "$status" -eq 0 ]
}

@test "unhealthy after a failure" {
  write_state failure "$(ago '-1 minute')"

  run bash "$HC"

  [ "$status" -ne 0 ]
}

@test "healthy before the first run has happened" {
  # A container that has only just started has nothing to report yet, and must
  # not be killed for it.
  run bash "$HC"

  [ "$status" -eq 0 ]
}

@test "unhealthy when the last success is older than the deadline" {
  write_state success "$(ago '-3 hours')"

  HEALTHCHECK_MAX_AGE=3600 run bash "$HC"

  [ "$status" -ne 0 ]
}

@test "a stale success is fine when no deadline is configured" {
  write_state success "$(ago '-30 days')"

  run bash "$HC"

  [ "$status" -eq 0 ]
}

@test "a corrupt state file is not fatal" {
  printf 'not json' >"$BACKUP_DIR/.last-run.json"

  run bash "$HC"

  [ "$status" -eq 0 ]
}
