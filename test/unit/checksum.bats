#!/usr/bin/env bats

setup() {
  set -euo pipefail
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  source "$REPO_ROOT/lib/log.sh"
  source "$REPO_ROOT/lib/checksum.sh"
  cd "$BATS_TEST_TMPDIR"
  echo "payload" >artifact.gz
}

@test "write_checksum creates a sidecar next to the artifact" {
  run write_checksum artifact.gz

  [ "$status" -eq 0 ]
  [ -f artifact.gz.sha256 ]
}

@test "checksum sidecar records the bare filename so it verifies after a download" {
  write_checksum "$BATS_TEST_TMPDIR/artifact.gz"

  run cat "$BATS_TEST_TMPDIR/artifact.gz.sha256"
  [[ "$output" == *"artifact.gz"* ]]
  [[ "$output" != *"$BATS_TEST_TMPDIR"* ]]
}

@test "verify_checksum accepts an intact artifact" {
  write_checksum artifact.gz

  run verify_checksum artifact.gz

  [ "$status" -eq 0 ]
}

@test "verify_checksum rejects a corrupted artifact" {
  write_checksum artifact.gz
  echo "tampered" >artifact.gz

  run verify_checksum artifact.gz

  [ "$status" -ne 0 ]
}

@test "verify_checksum fails when the sidecar is missing" {
  run verify_checksum artifact.gz

  [ "$status" -ne 0 ]
}
