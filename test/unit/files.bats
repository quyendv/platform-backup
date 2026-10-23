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

# list_archive FILE -> the archive's entries, directories without the slash.
list_archive() {
  zstd -dc -- "$1" | tar -tf - | sed 's|/$||'
}

# jenkins_selection: the shape of the Jenkins example's variables.
jenkins_selection() {
  export FILES_ROOT="$ROOT"
  export FILES_INCLUDE='*.xml jobs plugins/*/META-INF/MANIFEST.MF secrets'
  export FILES_EXCLUDE='secrets/master.key jobs/*/builds'
}

@test "dump archives the selection and nothing excluded" {
  jenkins_selection
  RUN_ID=20260101_000000 run --separate-stderr backend_dump "$WORK"
  [ "$status" -eq 0 ]
  [ "$output" = "files-20260101_000000.tar.zst" ]
  run list_archive "$WORK/files-20260101_000000.tar.zst"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'a.xml'* ]]
  [[ "$output" == *"jobs/x/config.xml"* ]]
  [[ "$output" == *"plugins/p1/META-INF/MANIFEST.MF"* ]]
  [[ "$output" == *"secrets/hudson.util.Secret"* ]]
  [[ "$output" != *master.key* ]]
  [[ "$output" != */builds/* ]]
  [[ "$output" != *p1.jpi* ]]
}

@test "excludes reach every depth" {
  jenkins_selection
  mkdir -p "$ROOT/jobs/a/jobs/b/branches/c/builds/9"
  echo log >"$ROOT/jobs/a/jobs/b/branches/c/builds/9/log"
  echo cfg >"$ROOT/jobs/a/jobs/b/branches/c/config.xml"
  RUN_ID=20260101_000000 backend_dump "$WORK" >/dev/null
  run list_archive "$WORK/files-20260101_000000.tar.zst"
  [ "$status" -eq 0 ]
  [[ "$output" == *"jobs/a/jobs/b/branches/c/config.xml"* ]]
  [[ "$output" != *builds* ]]
}

@test "owners are numeric in the archive" {
  jenkins_selection
  RUN_ID=20260101_000000 backend_dump "$WORK" >/dev/null
  run bash -c "zstd -dc '$WORK/files-20260101_000000.tar.zst' | tar -tvf - a.xml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$(id -u)/$(id -g)"* ]]
}

@test "a symlinked root is archived through the link" {
  ln -s "$ROOT" "$BATS_TEST_TMPDIR/link-root"
  FILES_ROOT="$BATS_TEST_TMPDIR/link-root" FILES_INCLUDE='*.xml' RUN_ID=20260101_000000 \
    run backend_dump "$WORK"
  [ "$status" -eq 0 ]
  run list_archive "$WORK/files-20260101_000000.tar.zst"
  [[ "$output" == *a.xml* ]]
}

@test "a symlink inside the root is kept as a link" {
  ln -s /etc "$ROOT/link"
  FILES_ROOT="$ROOT" FILES_INCLUDE='link' RUN_ID=20260101_000000 run backend_dump "$WORK"
  [ "$status" -eq 0 ]
  run bash -c "zstd -dc '$WORK/files-20260101_000000.tar.zst' | tar -tvf -"
  [[ "$output" == *"link -> /etc"* ]]
  [[ "$output" != *passwd* ]]
}

@test "tar exit 1 fails the dump" {
  jenkins_selection
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$BATS_TEST_TMPDIR/bin/tar"
  chmod +x "$BATS_TEST_TMPDIR/bin/tar"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" RUN_ID=20260101_000000 run backend_dump "$WORK"
  [ "$status" -ne 0 ]
  [[ "$output" == *tar* ]]
}

@test "an unreadable file fails the dump" {
  [ "$(id -u)" -ne 0 ] || skip "root reads everything"
  echo s >"$ROOT/locked.xml"
  chmod 000 "$ROOT/locked.xml"
  FILES_ROOT="$ROOT" FILES_INCLUDE='*.xml' RUN_ID=20260101_000000 run backend_dump "$WORK"
  [ "$status" -ne 0 ]
  [[ "$output" == *tar* ]]
}

@test "_files_matches follows tar exclusion semantics" {
  run _files_matches 'secrets/master.key' 'secrets/master.key'
  [ "$status" -eq 0 ]
  run _files_matches 'secrets/master.key' 'x/secrets/master.key'
  [ "$status" -eq 0 ]
  run _files_matches 'jobs/*/builds' 'jobs/a/jobs/b/builds/1/log'
  [ "$status" -eq 0 ]
  run _files_matches '*.jpi' 'plugins/p1.jpi'
  [ "$status" -eq 0 ]
  run _files_matches 'secrets/master.key' 'secrets/master.key.bak'
  [ "$status" -eq 1 ]
  run _files_matches 'secrets' 'notsecrets/x'
  [ "$status" -eq 1 ]
}

# archive_of INCLUDE [EXCLUDE] -> path of a fresh dump with that selection.
archive_of() {
  FILES_ROOT="$ROOT" FILES_INCLUDE="$1" FILES_EXCLUDE="${2:-}" RUN_ID=20260101_000000 \
    backend_dump "$WORK" >/dev/null
  printf '%s' "$WORK/files-20260101_000000.tar.zst"
}

@test "verify fails when a FILES_REQUIRE path is missing" {
  archive="$(archive_of '*.xml')"
  FILES_REQUIRE='a.xml secrets/hudson.util.Secret' run backend_verify "$archive"
  [ "$status" -ne 0 ]
  [[ "$output" == *"secrets/hudson.util.Secret"* ]]
}

@test "verify fails when an entry matches FILES_FORBID" {
  archive="$(archive_of 'secrets')"
  FILES_FORBID='secrets/master.key' run backend_verify "$archive"
  [ "$status" -ne 0 ]
  [[ "$output" == *"secrets/master.key"* ]]
}

@test "verify fails on a corrupt archive" {
  archive="$(archive_of '*.xml jobs')"
  head -c 20 "$archive" >"$WORK/cut.tar.zst"
  run backend_verify "$WORK/cut.tar.zst"
  [ "$status" -ne 0 ]
}

@test "verify passes a good archive" {
  archive="$(archive_of 'secrets jobs' 'secrets/master.key')"
  FILES_REQUIRE='jobs/x/config.xml secrets/hudson.util.Secret' FILES_FORBID='secrets/master.key' \
    run backend_verify "$archive"
  [ "$status" -eq 0 ]
}

# good_archive -> a dump of the Jenkins-shaped selection.
good_archive() {
  archive_of '*.xml jobs secrets plugins/*/META-INF/MANIFEST.MF' 'secrets/master.key jobs/*/builds'
}

@test "restore into an empty target recreates the selection byte for byte" {
  chmod 0640 "$ROOT/a.xml"
  archive="$(good_archive)"
  FILES_ROOT="$ROOT" FILES_RESTORE_TARGET="$WORK/target" run backend_restore "$archive"
  [ "$status" -eq 0 ]
  diff "$ROOT/a.xml" "$WORK/target/a.xml"
  diff -r "$ROOT/jobs/x/config.xml" "$WORK/target/jobs/x/config.xml"
  [ "$(stat -c %a "$WORK/target/a.xml")" = 640 ]
  [ ! -e "$WORK/target/secrets/master.key" ]
  [ ! -e "$WORK/target/jobs/x/builds" ]
}

@test "restore refuses a non-empty target and writes nothing" {
  archive="$(good_archive)"
  mkdir -p "$WORK/target"
  echo keep >"$WORK/target/keep.txt"
  FILES_ROOT="$ROOT" FILES_RESTORE_TARGET="$WORK/target" run backend_restore "$archive"
  [ "$status" -ne 0 ]
  [[ "$output" == *FILES_RESTORE_OVERWRITE* ]]
  [ "$(ls -A "$WORK/target")" = keep.txt ]
}

@test "overwrite replaces namesakes and leaves everything else" {
  archive="$(good_archive)"
  mkdir -p "$WORK/target"
  echo keep >"$WORK/target/keep.txt"
  echo stale >"$WORK/target/a.xml"
  FILES_ROOT="$ROOT" FILES_RESTORE_TARGET="$WORK/target" FILES_RESTORE_OVERWRITE=true \
    run backend_restore "$archive"
  [ "$status" -eq 0 ]
  [ "$(cat "$WORK/target/a.xml")" = a ]
  [ "$(cat "$WORK/target/keep.txt")" = keep ]
}

@test "a target holding only lost+found is empty" {
  archive="$(good_archive)"
  mkdir -p "$WORK/target/lost+found"
  FILES_ROOT="$ROOT" FILES_RESTORE_TARGET="$WORK/target" run backend_restore "$archive"
  [ "$status" -eq 0 ]
  [ -e "$WORK/target/a.xml" ]
}

@test "a missing target directory is created" {
  archive="$(good_archive)"
  FILES_ROOT="$ROOT" FILES_RESTORE_TARGET="$WORK/new/deeper" run backend_restore "$archive"
  [ "$status" -eq 0 ]
  [ -e "$WORK/new/deeper/a.xml" ]
}

@test "the default target is FILES_ROOT" {
  archive="$(good_archive)"
  unset FILES_RESTORE_TARGET
  FILES_ROOT="$WORK/fresh" run backend_restore "$archive"
  [ "$status" -eq 0 ]
  [ -e "$WORK/fresh/a.xml" ]
}

@test "restore stops before extracting when verify fails" {
  archive="$(good_archive)"
  head -c 20 "$archive" >"$WORK/cut.tar.zst"
  FILES_ROOT="$ROOT" FILES_RESTORE_TARGET="$WORK/target" run backend_restore "$WORK/cut.tar.zst"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a valid zstd"* ]]
  [ ! -e "$WORK/target" ] || [ -z "$(ls -A "$WORK/target")" ]
}

# fake_tar EXIT MESSAGE...: a tar that prints MESSAGEs on stderr and exits EXIT.
fake_tar() {
  local code="$1"
  shift
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  {
    printf '#!/usr/bin/env bash\n'
    # Written into the stub verbatim, to expand when the stub runs.
    # shellcheck disable=SC2016
    printf '[[ "$1" == --version ]] && { echo "tar (GNU tar) 1.35"; exit 0; }\n'
    for m in "$@"; do printf 'echo %q >&2\n' "tar: $m"; done
    printf 'exit %s\n' "$code"
  } >"$BATS_TEST_TMPDIR/bin/tar"
  chmod +x "$BATS_TEST_TMPDIR/bin/tar"
}

@test "a directory that changed while read only warns" {
  jenkins_selection
  fake_tar 1 'jobs/x: file changed as we read it'
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" RUN_ID=20260101_000000 run --separate-stderr backend_dump "$WORK"
  [ "$status" -eq 0 ]
  [ "$output" = "files-20260101_000000.tar.zst" ]
  [[ "$stderr" == *"jobs/x: file changed as we read it"* ]]
}

@test "a file removed before it was read only warns" {
  jenkins_selection
  fake_tar 1 'jobs/x/atomic123.tmp: File removed before we read it'
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" RUN_ID=20260101_000000 run backend_dump "$WORK"
  [ "$status" -eq 0 ]
}

@test "a regular file that changed while read fails the dump" {
  jenkins_selection
  fake_tar 1 'jobs/x: file changed as we read it' 'jobs/x/config.xml: file changed as we read it'
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" RUN_ID=20260101_000000 run backend_dump "$WORK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"jobs/x/config.xml"* ]]
}

@test "an unrecognised tar warning fails the dump" {
  jenkins_selection
  fake_tar 1 'jobs/x: something else entirely'
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" RUN_ID=20260101_000000 run backend_dump "$WORK"
  [ "$status" -ne 0 ]
}

@test "tar exit 2 fails the dump whatever it printed" {
  jenkins_selection
  fake_tar 2 'jobs/x: file changed as we read it'
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" RUN_ID=20260101_000000 run backend_dump "$WORK"
  [ "$status" -ne 0 ]
}

@test "validate in restore mode needs only the target's parent directory" {
  MODE=restore FILES_ROOT=/nonexistent FILES_RESTORE_TARGET="$WORK/target" run backend_validate
  [ "$status" -eq 0 ]
}

@test "validate in restore mode fails when the target's parent is missing" {
  MODE=restore FILES_ROOT=/nonexistent FILES_RESTORE_TARGET=/nonexistent/target run backend_validate
  [ "$status" -ne 0 ]
  [[ "$output" == */nonexistent* ]]
}

@test "a file that changed while read and is gone afterwards only warns" {
  jenkins_selection
  fake_tar 1 'jobs/x/atomic123tmp: file changed as we read it'
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" RUN_ID=20260101_000000 run backend_dump "$WORK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no file was torn"* ]]
}
