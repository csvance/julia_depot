#!/usr/bin/env bash
# A check that cannot fail proves nothing, so run one on an image that MUST fail it.
#
# Usage: expect_failure_test.sh <check executable> <pattern>
#
# The check is a julia_precompile_test target in this test's runfiles. It has to exit non-zero,
# and its output has to name the reason (the pattern), so that a check broken in some other way,
# one that crashes before looking at anything, does not pass here by accident.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../tests/common.sh"

check="$1"
pattern="$2"

rc=0
output="$("$check" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] ||
    fail "the check passed on an image built to fail it:
$output"
# A here-string, not a pipe: under pipefail a `printf | grep -q` that matches early can fail.
grep -q -- "$pattern" <<<"$output" ||
    fail "the check failed, but not with '$pattern':
$output"

echo "PASS: the check failed as it should, on: $(grep -m1 -- "$pattern" <<<"$output" | cut -c1-160)"
