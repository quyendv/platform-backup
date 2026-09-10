#!/usr/bin/env bats

setup() {
  set -euo pipefail
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  source "$REPO_ROOT/lib/log.sh"
  source "$REPO_ROOT/lib/env.sh"
}

# --- require_env -------------------------------------------------------------

@test "require_env accepts variables that are set and non-empty" {
  FOO=bar BAZ=qux run require_env FOO BAZ

  [ "$status" -eq 0 ]
}

@test "require_env rejects an unset variable and names it" {
  run require_env DEFINITELY_NOT_SET

  [ "$status" -eq 1 ]
  [[ "$output" == *"DEFINITELY_NOT_SET"* ]]
}

@test "require_env rejects a variable set to the empty string" {
  EMPTY='' run require_env EMPTY

  [ "$status" -eq 1 ]
  [[ "$output" == *"EMPTY"* ]]
}

@test "require_env reports every missing variable, not only the first" {
  run require_env MISSING_ONE MISSING_TWO

  [ "$status" -eq 1 ]
  [[ "$output" == *"MISSING_ONE"* ]]
  [[ "$output" == *"MISSING_TWO"* ]]
}

# --- require_int -------------------------------------------------------------

@test "require_int accepts zero" {
  KEEP=0 run require_int KEEP

  [ "$status" -eq 0 ]
}

@test "require_int rejects a negative number" {
  KEEP=-1 run require_int KEEP

  [ "$status" -eq 1 ]
  [[ "$output" == *"KEEP"* ]]
}

@test "require_int rejects a non-numeric value" {
  KEEP=seven run require_int KEEP

  [ "$status" -eq 1 ]
}

# --- parse_bool --------------------------------------------------------------

@test "parse_bool treats true, 1, yes and on as true" {
  for v in true TRUE 1 yes YES on; do
    run parse_bool "$v"
    [ "$status" -eq 0 ] || return 1
  done
}

@test "parse_bool treats false, 0, no, off and empty as false" {
  for v in false FALSE 0 no off ''; do
    run parse_bool "$v"
    [ "$status" -eq 1 ] || return 1
  done
}

@test "parse_bool rejects a value that is neither true nor false" {
  run parse_bool maybe

  [ "$status" -eq 2 ]
}

# --- bool_is_true ------------------------------------------------------------
# parse_bool returns 2 for garbage, which an `if` silently reads as false.
# bool_is_true refuses instead, so a typo in RESTORE_DROP cannot quietly
# turn a destructive flag off (or on).

@test "bool_is_true is true for a true-valued variable" {
  FLAG=yes run bool_is_true FLAG

  [ "$status" -eq 0 ]
}

@test "bool_is_true is false for a false-valued variable" {
  FLAG=off run bool_is_true FLAG

  [ "$status" -eq 1 ]
}

@test "bool_is_true is false for an unset variable" {
  run bool_is_true NEVER_SET_FLAG

  [ "$status" -eq 1 ]
}

@test "bool_is_true dies on a value that is neither, naming the variable" {
  FLAG=ture run bool_is_true FLAG

  [ "$status" -eq 1 ]
  [[ "$output" == *"FLAG"* ]]
  [[ "$output" == *"ture"* ]]
}
