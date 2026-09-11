# A fake `aws` on PATH: records every invocation and replays canned stdout.
# Lets the S3 helpers be tested for the commands they issue, without a network.

stub_aws_init() {
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  AWS_CALLS="$BATS_TEST_TMPDIR/aws-calls"
  AWS_STDOUT="$BATS_TEST_TMPDIR/aws-stdout"
  AWS_STDERR="$BATS_TEST_TMPDIR/aws-stderr"
  mkdir -p "$STUB_BIN"
  : >"$AWS_CALLS"
  : >"$AWS_STDOUT"
  : >"$AWS_STDERR"
  cat >"$STUB_BIN/aws" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$AWS_CALLS"
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
