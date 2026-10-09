#!/usr/bin/env bash
# The sysimage julia_sysimage writes is a plain file that Julia starts with, and the pinned
# compiler linked it behind the compiler the rule was given.
#
# Usage: sysimage_file_test.sh <sysimage.so> <julia> <project Manifest.toml> <stamp.txt>
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../tests/common.sh"

so="$(abspath "$1")"
julia_bin="$(abspath "$2")"
manifest="$(abspath "$3")"
stamp="$(abspath "$4")"

project="$(copy_project "$manifest" "$TEST_TMPDIR/project")"
assert_pinned_link "$so" 2.17

loaded="$(
    env JULIA_DEPOT_PATH="$(overlay_depot "$(stamp_value "$stamp" depot)" "$julia_bin")" \
        "$julia_bin" --startup-file=no --sysimage "$so" --project="$project" \
        -e 'print(Base.PkgId(Base.UUID("a8cc5b0e-0ffa-5ad4-8c14-923d3ee1735f"), "Crayons") in keys(Base.loaded_modules))'
)" || fail "julia could not start on $(basename "$so")"
[ "$loaded" = "true" ] || fail "julia started on $(basename "$so") but Crayons was not baked into it"

echo "PASS: $(basename "$so") starts Julia with Crayons baked in, linked for glibc 2.17 by the compiler the rule was given"
