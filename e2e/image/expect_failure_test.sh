#!/usr/bin/env bash
# Runs a check on an image built to fail it, to prove the check can fail.
#
# Usage: expect_failure_test.sh <check executable> <pattern>
#
# The check is a julia_precompile_test target in this test's runfiles. It must exit non-zero, and
# its output must contain the pattern naming the reason, so a check that crashes before
# inspecting anything does not pass here.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../tests/common.sh"

check="$1"
pattern="$2"

rc=0
output="$("$check" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] ||
    fail "the check passed on an image built to fail it:
$output"
# A here-string because under pipefail a `printf | grep -q` that matches early can fail.
grep -q -- "$pattern" <<<"$output" ||
    fail "the check failed, but not with '$pattern':
$output"

echo "PASS: the check failed as it should, on: $(grep -m1 -- "$pattern" <<<"$output" | cut -c1-160)"
