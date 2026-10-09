#!/usr/bin/env bash
# The sysimage in a julia_sysimage_layer was linked by the module's pinned zig, for glibc 2.17,
# and is byte for byte the julia_sysimage it was given: the layer ships that build, and a
# sysimage is not reproducible, so a second build would differ.
#
# Usage: sysimage_link_test.sh <sysimage layer.tar> <path in image> <julia_sysimage .so>
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../tests/common.sh"

layer="$(abspath "$1")"
path="${2#/}"
so="$(abspath "$3")"

tar --extract --file "$layer" --directory "$TEST_TMPDIR" "$path" ||
    fail "$(basename "$layer") has no $path"
assert_pinned_link "$TEST_TMPDIR/$path" 2.17
cmp -s "$TEST_TMPDIR/$path" "$so" ||
    fail "$(basename "$layer") holds a different sysimage than $(basename "$so"), so it was built twice"

echo "PASS: $(basename "$layer") ships $(basename "$so") as built, linked by the pinned compiler for glibc 2.17"
