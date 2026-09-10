#!/usr/bin/env bats
#
# prune_select decides which backup runs to delete. It is the only place in the
# codebase that can destroy a backup, so it is tested before anything else.

setup() {
  # Production sources lib/ from scripts running under `set -euo pipefail`.
  # Tests must run under the same options or they miss pipeline failures.
  set -euo pipefail
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  source "$REPO_ROOT/lib/retention.sh"
}

@test "keeps the newest N runs and marks the rest for deletion" {
  run prune_select 2 <<<$'20260101_000000\n20260102_000000\n20260103_000000'

  [ "$status" -eq 0 ]
  [ "$output" = "20260101_000000" ]
}

@test "KEEP=0 disables pruning instead of deleting everything" {
  run prune_select 0 <<<$'20260101_000000\n20260102_000000'

  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "never selects a name that is not a run folder" {
  run prune_select 1 <<<$'20260103_000000\nimportant-data\n20260101_000000\nREADME.txt\n2026010_00000'

  [ "$status" -eq 0 ]
  [ "$output" = "20260101_000000" ]
}

@test "succeeds on an empty listing" {
  run prune_select 3 </dev/null

  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "succeeds when every candidate is kept" {
  run prune_select 5 <<<$'20260102_000000\n20260101_000000'

  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "sorts by timestamp regardless of input order" {
  run prune_select 1 <<<$'20260101_000000\n20260103_000000\n20260102_000000'

  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "20260102_000000" ]
  [ "${lines[1]}" = "20260101_000000" ]
}
