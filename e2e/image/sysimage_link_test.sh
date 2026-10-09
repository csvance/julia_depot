#!/usr/bin/env bash
# The sysimage in a julia_sysimage_layer built with the default compiler was linked by the
# module's pinned zig, for glibc 2.17.
#
# Usage: sysimage_link_test.sh <sysimage layer.tar> <path in image>
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../tests/common.sh"

layer="$(abspath "$1")"
path="${2#/}"

tar --extract --file "$layer" --directory "$TEST_TMPDIR" "$path" ||
    fail "$(basename "$layer") has no $path"
assert_pinned_link "$TEST_TMPDIR/$path" 2.17

echo "PASS: $(basename "$layer") holds a sysimage linked by the pinned compiler for glibc 2.17"
