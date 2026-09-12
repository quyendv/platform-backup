#!/usr/bin/env bats
#
# Every environment variable a manifest or an example sets must be one the
# image actually reads. A typo passes YAML validation, passes a dry run, and
# then silently does nothing — KEEP_REMOTE spelled KEEP_REMOTES prunes nothing
# and says nothing.

setup() {
  set -euo pipefail
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

# Keys the AWS CLI reads directly. The image deliberately never touches these,
# which is what lets an instance role or IRSA supply them.
aws_native() {
  cat <<'LIST'
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
AWS_SESSION_TOKEN
AWS_REGION
AWS_DEFAULT_REGION
AWS_ENDPOINT_URL
AWS_ENDPOINT_URL_S3
LIST
}

# Everything the shell sources actually reference.
known_keys() {
  {
    aws_native
    grep -rhoE '\b[A-Z][A-Z0-9_]{2,}\b' \
      "$REPO_ROOT"/lib/*.sh "$REPO_ROOT"/entrypoint.sh \
      "$REPO_ROOT"/healthcheck.sh "$REPO_ROOT"/backends/*/backend.sh
  } | LC_ALL=C sort -u
}

# Keys a manifest's stringData or an .env.example sets, commented or not.
declared_keys() {
  {
    grep -rhoE '^[[:space:]]*#?[[:space:]]*[A-Z][A-Z0-9_]{2,}:' \
      "$REPO_ROOT"/backends/*/k8s/*.yaml
    grep -rhoE '^[[:space:]]*#?[[:space:]]*[A-Z][A-Z0-9_]{2,}=' \
      "$REPO_ROOT"/backends/*/.env.example
  } | tr -d ' #:=' | LC_ALL=C sort -u
}

@test "every declared variable is one the image reads" {
  local unknown
  unknown="$(comm -23 <(declared_keys) <(known_keys) | tr '\n' ' ')"

  [ -z "$unknown" ] || {
    echo "Declared but never read: $unknown" >&2
    false
  }
}

@test "the guard itself catches a typo" {
  # A check that cannot fail is not a check.
  run bash -c "comm -23 <(printf 'KEEP_REMOTES\n') <(printf 'KEEP_REMOTE\n')"

  [ "$output" = "KEEP_REMOTES" ]
}

@test "every notification channel documented is one notify.sh dispatches" {
  local declared dispatched
  declared="$(grep -rhoE 'NOTIFY_[A-Z0-9_]+' "$REPO_ROOT"/backends/*/k8s/*.yaml | LC_ALL=C sort -u)"
  dispatched="$(grep -oE 'NOTIFY_[A-Z0-9_]+' "$REPO_ROOT/lib/notify.sh" | LC_ALL=C sort -u)"

  run comm -23 <(printf '%s\n' "$declared") <(printf '%s\n' "$dispatched")
  [ "$output" = "" ]
}
