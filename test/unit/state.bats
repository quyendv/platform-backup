#!/usr/bin/env bats
#
# Every run records its outcome. This is what a healthcheck reads, what the
# notifier turns into a message, and what makes "did last night's backup work"
# answerable without grepping logs.

setup() {
  set -euo pipefail
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  source "$REPO_ROOT/lib/log.sh"
  source "$REPO_ROOT/lib/env.sh"
  source "$REPO_ROOT/lib/state.sh"
  BACKUP_DIR="$BATS_TEST_TMPDIR/backup"
  mkdir -p "$BACKUP_DIR"
  STATE_FILE="$BACKUP_DIR/.last-run.json"
}

@test "a successful run records outcome, backend and run id" {
  state_write success postgresql 20260101_000000 '' 0

  run jq -r '.outcome, .backend, .run_id' "$STATE_FILE"
  [ "${lines[0]}" = "success" ]
  [ "${lines[1]}" = "postgresql" ]
  [ "${lines[2]}" = "20260101_000000" ]
}

@test "a failed run records the stage and the message" {
  state_write failure postgresql 20260101_000000 'upload: Access Denied' 4

  run jq -r '.outcome, .error, .exit_code' "$STATE_FILE"
  [ "${lines[0]}" = "failure" ]
  [ "${lines[1]}" = "upload: Access Denied" ]
  [ "${lines[2]}" = "4" ]
}

@test "the state file is valid JSON even when the error contains quotes and newlines" {
  # Error text comes from other tools. Hand-built JSON breaks here, which is
  # why jq does the encoding.
  state_write failure postgresql 20260101_000000 'he said "no" and
then stopped \ hard' 3

  run jq -e . "$STATE_FILE"
  [ "$status" -eq 0 ]

  run jq -r '.error' "$STATE_FILE"
  [[ "$output" == *'"no"'* ]]
}

@test "state_previous_outcome reports none before any run" {
  run state_previous_outcome

  [ "$output" = "none" ]
}

@test "state_previous_outcome reports the last recorded outcome" {
  state_write failure postgresql 20260101_000000 'boom' 3

  run state_previous_outcome

  [ "$output" = "failure" ]
}

@test "writing state does not clobber a run directory" {
  # The state file lives in BACKUP_DIR alongside run folders and must never be
  # mistaken for one.
  state_write success postgresql 20260101_000000 '' 0

  run basename "$STATE_FILE"
  [[ "$output" == .* ]]
}

@test "state_write survives a read-only backup dir without failing the run" {
  # Losing the state file must never turn a good backup into a failed one.
  chmod 500 "$BACKUP_DIR"

  run state_write success postgresql 20260101_000000 '' 0
  chmod 700 "$BACKUP_DIR"

  [ "$status" -eq 0 ]
}
