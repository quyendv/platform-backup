# A fake `aws` on PATH: records every invocation and replays canned stdout.
# Lets the S3 helpers be tested for the commands they issue, without a network.

stub_aws_init() {
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  AWS_CALLS="$BATS_TEST_TMPDIR/aws-calls"
  AWS_STDOUT="$BATS_TEST_TMPDIR/aws-stdout"
  AWS_STDERR="$BATS_TEST_TMPDIR/aws-stderr"
  AWS_OBJECTS="$BATS_TEST_TMPDIR/aws-objects"
  mkdir -p "$STUB_BIN" "$AWS_OBJECTS"
  : >"$AWS_CALLS"
  : >"$AWS_STDOUT"
  : >"$AWS_STDERR"
  cat >"$STUB_BIN/aws" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$AWS_CALLS"
# \`aws s3 cp s3://.../<name> -\` streams an object: serve it from AWS_OBJECTS.
if [[ "\$1 \$2" == "s3 cp" && "\$3" == s3://* && "\${4:-}" == "-" ]]; then
  cat "$AWS_OBJECTS/\${3##*/}" || exit 1
  exit 0
fi
cat "$AWS_STDOUT"
cat "$AWS_STDERR" >&2
exit \${STUB_AWS_EXIT:-0}
STUB
  chmod +x "$STUB_BIN/aws"
  PATH="$STUB_BIN:$PATH"
}

stub_aws_stdout() {
  printf '%s\n' "$1" >"$AWS_STDOUT"
  export STUB_AWS_EXIT=0
}
# An empty prefix makes `aws s3 ls` exit 1 with nothing on stderr; a real
# failure writes to stderr. The stub has to be able to express both.
stub_aws_empty() {
  : >"$AWS_STDOUT"
  export STUB_AWS_EXIT=1
}
stub_aws_error() {
  : >"$AWS_STDOUT"
  printf '%s\n' "${1:-An error occurred (NoSuchBucket)}" >"$AWS_STDERR"
  export STUB_AWS_EXIT=254
}
aws_calls() { cat "$AWS_CALLS"; }

# Freezes only the run-id clock. Everything else — log timestamps — passes
# through to the real date, so log output stays readable.
stub_fixed_run_id() {
  local real
  real="$(command -v date)"
  cat >"$STUB_BIN/date" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  [[ "\$a" == "+%Y%m%d_%H%M%S" ]] && { printf '%s\n' "${1:-20260101_000000}"; exit 0; }
done
exec "$real" "\$@"
STUB
  chmod +x "$STUB_BIN/date"
}

# ls_keys KEY... -> what `aws s3 ls --recursive` prints for these object keys.
ls_keys() {
  local key
  for key in "$@"; do
    printf '2026-01-01 00:00:00       2048 %s\n' "$key"
  done
}

# stub_aws_keys KEY... — the bucket holds exactly these objects.
stub_aws_keys() {
  ls_keys "$@" >"$AWS_STDOUT"
  export STUB_AWS_EXIT=0
}

# stub_aws_object NAME CONTENT — what streaming the object NAME returns.
stub_aws_object() {
  printf '%s' "$2" >"$AWS_OBJECTS/$1"
}
