#!/usr/bin/env bats

setup() {
  set -euo pipefail
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  source "$REPO_ROOT/lib/log.sh"
  source "$REPO_ROOT/lib/env.sh"
  source "$REPO_ROOT/lib/s3.sh"
}

# --- normalize_prefix --------------------------------------------------------

@test "normalize_prefix strips leading and trailing slashes" {
  run normalize_prefix "/backups/postgres/"

  [ "$output" = "backups/postgres" ]
}

@test "normalize_prefix collapses repeated slashes" {
  run normalize_prefix "backups//postgres///daily"

  [ "$output" = "backups/postgres/daily" ]
}

@test "normalize_prefix maps an empty prefix to an empty string" {
  run normalize_prefix ""

  [ "$output" = "" ]
}

@test "normalize_prefix maps a slash-only prefix to an empty string" {
  run normalize_prefix "///"

  [ "$output" = "" ]
}

# --- s3_key ------------------------------------------------------------------

@test "s3_key joins prefix, run id and filename" {
  run s3_key "backups/postgres" "20260305_020000" "postgresql-20260305_020000.dump.gz"

  [ "$output" = "backups/postgres/20260305_020000/postgresql-20260305_020000.dump.gz" ]
}

@test "s3_key omits the prefix segment when the prefix is empty" {
  run s3_key "" "20260305_020000" "dump.gz"

  [ "$output" = "20260305_020000/dump.gz" ]
}

@test "s3_key normalizes a messy prefix" {
  run s3_key "/backups//postgres/" "20260305_020000" "dump.gz"

  [ "$output" = "backups/postgres/20260305_020000/dump.gz" ]
}

# --- s3_enabled --------------------------------------------------------------

@test "s3_enabled is false when no bucket is configured" {
  S3_BUCKET='' run s3_enabled

  [ "$status" -eq 1 ]
}

@test "s3_enabled is true when a bucket is configured" {
  S3_BUCKET=my-bucket run s3_enabled

  [ "$status" -eq 0 ]
}

# --- s3_list_runs ------------------------------------------------------------
# A stub `aws` on PATH lets these assert both the parsing and the command line,
# without reaching a real object store.

stub_aws() {
  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_DIR"
  cat >"$STUB_DIR/aws" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$BATS_TEST_TMPDIR/aws-calls"
cat <<'OUT'
$1
OUT
STUB
  chmod +x "$STUB_DIR/aws"
  PATH="$STUB_DIR:$PATH"
}

@test "s3_list_runs returns run ids from a prefix listing" {
  stub_aws "                           PRE 20260305_020000/
                           PRE 20260305_060000/"

  S3_BUCKET=b run s3_list_runs "backups/pg"

  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "20260305_020000" ]
  [ "${lines[1]}" = "20260305_060000" ]
}

@test "s3_list_runs ignores objects that are not run folders" {
  stub_aws "                           PRE latest/
                           PRE 20260305_020000/
2026-03-05 02:00:00       1024 stray-file.txt"

  S3_BUCKET=b run s3_list_runs "backups/pg"

  [ "$status" -eq 0 ]
  [ "$output" = "20260305_020000" ]
}

@test "s3_list_runs succeeds with no output on an empty prefix" {
  stub_aws ""

  S3_BUCKET=b run s3_list_runs "backups/pg"

  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "s3_list_runs lists the prefix with a trailing slash" {
  stub_aws ""

  S3_BUCKET=my-bucket run s3_list_runs "backups/pg"

  run cat "$BATS_TEST_TMPDIR/aws-calls"
  [[ "$output" == *"s3://my-bucket/backups/pg/"* ]]
  # `aws s3 ls` has no --delimiter flag; passing one is a hard error.
  [[ "$output" != *"--delimiter"* ]]
}
