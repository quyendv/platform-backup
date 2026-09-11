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

# --- an empty prefix is not a failure ----------------------------------------

@test "an empty prefix lists nothing and succeeds" {
  # The first backup against a fresh bucket: `aws s3 ls` exits 1 with no
  # output. Treating that as an error would break every new deployment.
  stub_aws_empty

  run s3_list_runs "backups/pg"

  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "pruning an empty prefix succeeds and deletes nothing" {
  stub_aws_empty

  run prune_remote "backups/pg" 1
  [ "$status" -eq 0 ]

  run aws_calls
  [[ "$output" != *"s3 rm"* ]]
}

# --- listing failures must not look like "no backups" ------------------------

@test "s3_list_runs fails when the AWS CLI reports an error" {
  # Bad credentials, a missing bucket or a denied policy. These used to be
  # swallowed by 2>/dev/null and reported as an empty listing, which sends you
  # hunting for missing backups instead of a broken configuration.
  stub_aws_error "An error occurred (NoSuchBucket)"

  run s3_list_runs "backups/pg"

  [ "$status" -ne 0 ]
  [[ "$output" == *"NoSuchBucket"* ]]
}

@test "s3_resolve_run reports the listing failure, not a missing backup" {
  stub_aws_error "An error occurred (AccessDenied)"

  run s3_resolve_run "backups/pg" ""

  [ "$status" -ne 0 ]
  [[ "$output" != *"No backup runs found"* ]]
}

@test "prune_remote refuses to run when the listing failed" {
  # Pruning nothing is harmless; reporting success for work never attempted
  # is not.
  stub_aws_error "An error occurred (AccessDenied)"

  run prune_remote "backups/pg" 1

  [ "$status" -ne 0 ]
}
