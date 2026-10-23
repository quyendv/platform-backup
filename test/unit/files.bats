#!/usr/bin/env bats
#
# The files adapter, against real GNU tar and zstd. What is pinned here comes
# from docs/superpowers/specs/2026-10-23-files-backend-design.md: the include
# list is expanded by the adapter (tar does not glob its input names), every
# include must match something, exclusions reach every depth, and verify turns
# FILES_REQUIRE and FILES_FORBID into checked properties of the archive.

# Every @test body is its own subshell, which is exactly where these variables
# are meant to live; shellcheck reads that as an accidental scope.
# shellcheck disable=SC2030,SC2031
bats_require_minimum_version 1.5.0

setup() {
  set -euo pipefail
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  source "$REPO_ROOT/lib/log.sh"
  source "$REPO_ROOT/lib/env.sh"
  source "$REPO_ROOT/backends/files/backend.sh"
  ROOT="$BATS_TEST_TMPDIR/root"
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK"
  seed_tree "$ROOT"
}

# seed_tree DIR: the shape of an application home with state, caches and a key.
seed_tree() {
  local d="$1"
  mkdir -p "$d/jobs/x/builds/1" "$d/plugins/p1/META-INF" "$d/secrets" "$d/.ssh"
  echo a >"$d/a.xml"
  echo b >"$d/b.xml"
  echo cfg >"$d/jobs/x/config.xml"
  echo log >"$d/jobs/x/builds/1/log"
  echo manifest >"$d/plugins/p1/META-INF/MANIFEST.MF"
  echo jpi >"$d/plugins/p1.jpi"
  echo key >"$d/secrets/master.key"
  echo secret >"$d/secrets/hudson.util.Secret"
  echo hosts >"$d/.ssh/known_hosts"
}

expand_sorted() {
  _files_expand | LC_ALL=C sort
}

@test "validate fails without FILES_ROOT" {
  unset FILES_ROOT
  run backend_validate
  [ "$status" -ne 0 ]
  [[ "$output" == *FILES_ROOT* ]]
}

@test "validate fails when FILES_ROOT is a file" {
  FILES_ROOT="$ROOT/a.xml" run backend_validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a directory"* ]]
}

@test "validate fails when FILES_ROOT does not exist" {
  FILES_ROOT="$ROOT/nope" run backend_validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a directory"* ]]
}

@test "validate fails naming an include that matches nothing" {
  FILES_ROOT="$ROOT" FILES_INCLUDE='*.xml nope/*' run backend_validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"nope/*"* ]]
}

@test "a literal include that does not exist fails" {
  FILES_ROOT="$ROOT" FILES_INCLUDE='missing.xml' run backend_validate
  [ "$status" -ne 0 ]
  [[ "$output" == *missing.xml* ]]
}

@test "validate passes a selection that matches" {
  FILES_ROOT="$ROOT" FILES_INCLUDE='*.xml jobs' run backend_validate
  [ "$status" -eq 0 ]
}

@test "globs expand relative to the root, including **" {
  FILES_ROOT="$ROOT" FILES_INCLUDE='*.xml plugins/**/MANIFEST.MF' run expand_sorted
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'a.xml\nb.xml\nplugins/p1/META-INF/MANIFEST.MF')" ]
}

@test "the default include is the whole root" {
  unset FILES_INCLUDE
  FILES_ROOT="$ROOT" run _files_expand
  [ "$status" -eq 0 ]
  [ "$output" = "." ]
}

@test "newlines and spaces both separate entries" {
  FILES_ROOT="$ROOT" FILES_INCLUDE=$'a.xml\n  b.xml   .ssh/known_hosts' run expand_sorted
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '.ssh/known_hosts\na.xml\nb.xml')" ]
}

@test "a glob does not match dotfiles unless it names them" {
  FILES_ROOT="$ROOT" FILES_INCLUDE='*' run _files_expand
  [ "$status" -eq 0 ]
  [[ "$output" != *.ssh* ]]
}

@test "3000 matched paths are listed in full" {
  mkdir -p "$ROOT/many"
  (cd "$ROOT/many" && seq 1 3000 | xargs touch)
  FILES_ROOT="$ROOT" FILES_INCLUDE='many/*' run _files_expand
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3000 ]
}

@test "validate succeeds in fetch mode with no FILES_ROOT" {
  unset FILES_ROOT
  MODE=fetch run backend_validate
  [ "$status" -eq 0 ]
}
