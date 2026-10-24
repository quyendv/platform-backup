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

# Keys HashiCorp's own vault tooling reads: VAULT_CACERT by the CLI in the
# vault image, SKIP_SETCAP by the entrypoint of the Vault Agent sidecar.
vault_native() {
  cat <<'LIST'
VAULT_CACERT
SKIP_SETCAP
LIST
}

# Keys Docker Compose interpolates into backends/*/docker/compose.yaml. They
# live in the same .env, but the image never sees them.
compose_native() {
  cat <<'LIST'
RESTART_POLICY
SQLITE_VOLUME
FILES_SOURCE
FILES_RESTORE_DIR
JENKINS_HOME_DIR
RESTORE_TARGET_DIR
LIST
}

# Everything the shell sources actually reference.
known_keys() {
  {
    aws_native
    vault_native
    compose_native
    grep -rhoE '\b[A-Z][A-Z0-9_]{2,}\b' \
      "$REPO_ROOT"/lib/*.sh "$REPO_ROOT"/entrypoint.sh \
      "$REPO_ROOT"/healthcheck.sh "$REPO_ROOT"/backends/*/backend.sh
  } | LC_ALL=C sort -u
}

# Keys a manifest's stringData, a compose file's environment or an
# .env.example sets, commented or not; worked examples included.
declared_keys() {
  local -a yaml env
  shopt -s nullglob
  yaml=("$REPO_ROOT"/backends/*/k8s/*.yaml "$REPO_ROOT"/backends/*/docker/compose.yaml
    "$REPO_ROOT"/backends/*/examples/*/compose.yaml)
  env=("$REPO_ROOT"/backends/*/.env.example "$REPO_ROOT"/backends/*/examples/*/.env.example)
  shopt -u nullglob
  {
    grep -rhoE '^[[:space:]]*#?[[:space:]]*[A-Z][A-Z0-9_]{2,}:' "${yaml[@]}"
    grep -rhoE '^[[:space:]]*#?[[:space:]]*[A-Z][A-Z0-9_]{2,}=' "${env[@]}"
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
