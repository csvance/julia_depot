#!/usr/bin/env bash
# sysimage.sh `auto` picks the PackageCompiler environment for the running Julia, it links with
# the compiler it is given, and the sysimage it builds loads.
#
# `auto` makes the module's sysimage support version-agnostic: the consumer's genrule names no
# version, and the script selects julia/sysimage/v<major>.<minor>/ from the running Julia. A wrong
# selection fails, because the script compares that environment's julia_version against the
# running Julia and exits; sysimage_wrong_minor_test.sh checks that branch. So a clean build here
# proves the selection was right.
#
# The compiler is a user-supplied one, recording_cc.sh, which records each call and hands it to
# the module's pinned compiler. The record shows the given compiler was used; the link marks and
# glibc symbol versions of the output show the pinned compiler behind it did the link.
#
# A sysimage that compiles but cannot be loaded would fail a deployment, so the test starts Julia
# on the image and uses the package baked into it.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

sysimage_sh="$(abspath "$1")"
julia_bin="$(abspath "$2")"
manifest="$(abspath "$3")"
stamp="$(abspath "$4")"
sysimage_stamp="$(abspath "$5")"
want_minor="$6"
user_cc="$(abspath "$7")"
pinned_cc="$(abspath "$8")"

project="$(copy_project "$manifest" "$TEST_TMPDIR/project")"
src_depot="$(first_depot "$(stamp_value "$stamp" depot)")"

# Both depots instantiate into the ambient depot, so the PackageCompiler environment for this
# minor is in the same tree as the project. If that stopped being true, `auto` would find the
# environment's files but not its packages, so it is asserted here.
[ "$(first_depot "$(stamp_value "$sysimage_stamp" depot)")" = "$src_depot" ] ||
    fail "the PackageCompiler environment was instantiated into a different depot than the project"
[ "$(stamp_value "$sysimage_stamp" julia_version)" = "$(stamp_value "$stamp" julia_version)" ] ||
    fail "the PackageCompiler environment was instantiated under a different Julia than the project"

out="$TEST_TMPDIR/sysimage.so"
log="$TEST_TMPDIR/sysimage.log"

# CPU target generic instead of sysimage.sh's portable default: this test is about environment
# selection, and compiling four CPU clones per build, with builds in parallel, ran a CI runner
# out of memory.
cc_log="$TEST_TMPDIR/cc.log"
env JULIA_DEPOT_BIN="$julia_bin" \
    JULIA_DEPOT_PATH="$(overlay_depot "$src_depot" "$julia_bin")" \
    JULIA_DEPOT_SYSIMAGE_PACKAGES="Crayons" \
    JULIA_DEPOT_SYSIMAGE_CPU_TARGET="generic" \
    JULIA_DEPOT_SYSIMAGE_CC="$user_cc" \
    E2E_CC_LOG="$cc_log" E2E_CC_NEXT="$pinned_cc" \
    "$sysimage_sh" "$project" auto "$out" > "$log" 2>&1 ||
    fail "sysimage.sh auto failed under julia $want_minor:
$(cat "$log")"

# The selection messages appear only on failure paths. One on a successful run would mean the
# script used a different environment than the assertions below assume.
if grep -qE 'no PackageCompiler environment|was resolved under Julia' "$log"; then
    fail "sysimage.sh auto complained about environment selection:
$(cat "$log")"
fi

[ -f "$out" ] || fail "sysimage.sh auto reported success but wrote no $out"
size="$(stat -c %s "$out")"
[ "$size" -gt 10000000 ] ||
    fail "the sysimage is only $size bytes, which is not an incremental Julia image"

grep -q -- "-shared" "$cc_log" 2>/dev/null ||
    fail "sysimage.sh did not link with the compiler in JULIA_DEPOT_SYSIMAGE_CC; its calls:
$(cat "$cc_log" 2>/dev/null)"
assert_pinned_link "$out" 2.17

# Start Julia on the sysimage and use the package baked into it.
loaded="$(
    env JULIA_DEPOT_PATH="$(overlay_depot "$src_depot" "$julia_bin")" \
        "$julia_bin" --startup-file=no --sysimage "$out" --project="$project" \
        -e 'using Crayons; print(Crayons.Crayon(bold = true) isa Crayons.Crayon)'
)" || fail "julia could not start on the sysimage it just built"
[ "$loaded" = "true" ] ||
    fail "the sysimage loaded but Crayons did not come out of it: got '$loaded'"

echo "PASS: sysimage.sh auto built a $((size / 1024 / 1024)) MiB image on julia $want_minor with the given compiler, linked for glibc 2.17, and it loads"
