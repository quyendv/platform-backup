# A fake `aws` on PATH: records every invocation and replays canned stdout.
# Lets the S3 helpers be tested for the commands they issue, without a network.

stub_aws_init() {
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  AWS_CALLS="$BATS_TEST_TMPDIR/aws-calls"
  AWS_STDOUT="$BATS_TEST_TMPDIR/aws-stdout"
  mkdir -p "$STUB_BIN"
  : >"$AWS_CALLS"
  : >"$AWS_STDOUT"
  cat >"$STUB_BIN/aws" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$AWS_CALLS"
cat "$AWS_STDOUT"
exit \${STUB_AWS_EXIT:-0}
STUB
  chmod +x "$STUB_BIN/aws"
  PATH="$STUB_BIN:$PATH"
}

stub_aws_stdout() { printf '%s\n' "$1" >"$AWS_STDOUT"; }
aws_calls() { cat "$AWS_CALLS"; }
