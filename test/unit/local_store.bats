#!/usr/bin/env bats
#
# prune_local removes directories from disk. Tested against real directories.

setup() {
  set -euo pipefail
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  source "$REPO_ROOT/lib/log.sh"
  source "$REPO_ROOT/lib/env.sh"
  source "$REPO_ROOT/lib/retention.sh"
  source "$REPO_ROOT/lib/local_store.sh"
  BACKUP_DIR="$BATS_TEST_TMPDIR/backup"
  mkdir -p "$BACKUP_DIR"
}

make_runs() {
  local r
  for r in "$@"; do
    mkdir -p "$BACKUP_DIR/$r"
    echo data >"$BACKUP_DIR/$r/artifact.gz"
  done
}

@test "local_list_runs returns run directories only" {
  make_runs 20260101_000000 20260102_000000
  mkdir -p "$BACKUP_DIR/scratch"
  echo x >"$BACKUP_DIR/loose-file"

  run local_list_runs "$BACKUP_DIR"

  [ "${#lines[@]}" -eq 2 ]
  [[ "$output" == *"20260101_000000"* ]]
  [[ "$output" == *"20260102_000000"* ]]
}

@test "local_list_runs succeeds on an empty backup dir" {
  run local_list_runs "$BACKUP_DIR"

  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "prune_local deletes the oldest runs beyond the keep count" {
  make_runs 20260101_000000 20260102_000000 20260103_000000

  run prune_local "$BACKUP_DIR" 2

  [ "$status" -eq 0 ]
  [ ! -d "$BACKUP_DIR/20260101_000000" ]
  [ -d "$BACKUP_DIR/20260102_000000" ]
  [ -d "$BACKUP_DIR/20260103_000000" ]
}

@test "prune_local leaves everything alone when keep is zero" {
  make_runs 20260101_000000 20260102_000000

  run prune_local "$BACKUP_DIR" 0

  [ "$status" -eq 0 ]
  [ -d "$BACKUP_DIR/20260101_000000" ]
  [ -d "$BACKUP_DIR/20260102_000000" ]
}

@test "prune_local never removes a directory that is not a run folder" {
  make_runs 20260101_000000 20260102_000000
  mkdir -p "$BACKUP_DIR/keep-me"

  run prune_local "$BACKUP_DIR" 1

  [ "$status" -eq 0 ]
  [ -d "$BACKUP_DIR/keep-me" ]
  [ ! -d "$BACKUP_DIR/20260101_000000" ]
}

@test "prune_local removes the whole run directory, artifact and checksum together" {
  make_runs 20260101_000000 20260102_000000
  echo sum >"$BACKUP_DIR/20260101_000000/artifact.gz.sha256"

  run prune_local "$BACKUP_DIR" 1

  [ "$status" -eq 0 ]
  [ ! -e "$BACKUP_DIR/20260101_000000/artifact.gz" ]
  [ ! -e "$BACKUP_DIR/20260101_000000/artifact.gz.sha256" ]
}
