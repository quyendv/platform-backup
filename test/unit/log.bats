#!/usr/bin/env bats

setup() {
  set -euo pipefail
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  source "$REPO_ROOT/lib/log.sh"
}

@test "die writes the message to stderr and exits non-zero" {
  run bash -c "source '$REPO_ROOT/lib/log.sh'; die 'boom' 2>&1 1>/dev/null"

  [ "$status" -eq 1 ]
  [[ "$output" == *"boom"* ]]
}

@test "log_info writes to stderr, keeping stdout free for data" {
  # Callers capture command substitution output (backend_dump echoes a filename,
  # _fetch_into echoes a path). Any log line on stdout would corrupt that value.
  run bash -c "source '$REPO_ROOT/lib/log.sh'; log_info 'hello' 2>/dev/null"
  [ "$output" = "" ]

  run bash -c "source '$REPO_ROOT/lib/log.sh'; log_info 'hello' 2>&1 1>/dev/null"
  [[ "$output" == *"hello"* ]]
}

@test "log_error writes to stderr, not stdout" {
  run bash -c "source '$REPO_ROOT/lib/log.sh'; log_error 'bad' 2>/dev/null"

  [ "$output" = "" ]
}

@test "emits no ANSI escapes when the stream is not a TTY" {
  run bash -c "source '$REPO_ROOT/lib/log.sh'; log_info 'plain' 2>&1"

  [[ "$output" != *$'\033'* ]]
}
