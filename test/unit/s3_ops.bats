#!/usr/bin/env bats

setup() {
  set -euo pipefail
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  source "$REPO_ROOT/test/unit/helpers/stub_aws.bash"
  source "$REPO_ROOT/lib/log.sh"
  source "$REPO_ROOT/lib/env.sh"
  source "$REPO_ROOT/lib/retention.sh"
  source "$REPO_ROOT/lib/s3.sh"
  stub_aws_init
  S3_BUCKET=my-bucket
  DRY_RUN=false
}

# --- s3_delete_run -----------------------------------------------------------

@test "s3_delete_run removes the whole run prefix recursively" {
  s3_delete_run backups/pg 20260101_000000

  run aws_calls
  [[ "$output" == *"s3 rm s3://my-bucket/backups/pg/20260101_000000/ --recursive"* ]]
}

@test "s3_delete_run issues no command when DRY_RUN is on" {
  DRY_RUN=true run s3_delete_run backups/pg 20260101_000000
  [ "$status" -eq 0 ]

  run aws_calls
  [ "$output" = "" ]
}

# --- prune_remote ------------------------------------------------------------

@test "prune_remote deletes only the runs beyond the keep count" {
  stub_aws_stdout "                           PRE 20260101_000000/
                           PRE 20260102_000000/
                           PRE 20260103_000000/"

  prune_remote backups/pg 2

  run aws_calls
  [[ "$output" == *"20260101_000000/ --recursive"* ]]
  [[ "$output" != *"20260102_000000/ --recursive"* ]]
  [[ "$output" != *"20260103_000000/ --recursive"* ]]
}

@test "prune_remote deletes nothing when keep is zero" {
  stub_aws_stdout "                           PRE 20260101_000000/
                           PRE 20260102_000000/"

  run prune_remote backups/pg 0
  [ "$status" -eq 0 ]

  run aws_calls
  [[ "$output" != *"s3 rm"* ]]
}

# --- s3_resolve_run ----------------------------------------------------------

@test "s3_resolve_run picks the newest run when no timestamp is pinned" {
  stub_aws_stdout "                           PRE 20260101_000000/
                           PRE 20260303_120000/
                           PRE 20260102_000000/"

  run s3_resolve_run backups/pg ""

  [ "$status" -eq 0 ]
  [ "$output" = "20260303_120000" ]
}

@test "s3_resolve_run honours a pinned timestamp that exists" {
  stub_aws_stdout "                           PRE 20260101_000000/
                           PRE 20260102_000000/"

  run s3_resolve_run backups/pg 20260101_000000

  [ "$status" -eq 0 ]
  [ "$output" = "20260101_000000" ]
}

@test "s3_resolve_run fails when the pinned timestamp does not exist" {
  stub_aws_stdout "                           PRE 20260102_000000/"

  run s3_resolve_run backups/pg 20260101_000000

  [ "$status" -ne 0 ]
  [[ "$output" == *"20260101_000000"* ]]
}

@test "s3_resolve_run fails when there are no backups at all" {
  stub_aws_stdout ""

  run s3_resolve_run backups/pg ""

  [ "$status" -ne 0 ]
  [[ "$output" == *"No backup"* ]]
}

# --- s3_upload_run -----------------------------------------------------------

@test "s3_upload_run uploads the run directory to the matching prefix" {
  mkdir -p "$BATS_TEST_TMPDIR/run"
  echo x >"$BATS_TEST_TMPDIR/run/pg.dump.gz"

  s3_upload_run "$BATS_TEST_TMPDIR/run" backups/pg 20260101_000000

  run aws_calls
  [[ "$output" == *"s3://my-bucket/backups/pg/20260101_000000/"* ]]
}

@test "s3_upload_run issues no command when DRY_RUN is on" {
  mkdir -p "$BATS_TEST_TMPDIR/run"
  echo x >"$BATS_TEST_TMPDIR/run/pg.dump.gz"

  DRY_RUN=true run s3_upload_run "$BATS_TEST_TMPDIR/run" backups/pg 20260101_000000
  [ "$status" -eq 0 ]

  run aws_calls
  [ "$output" = "" ]
}
