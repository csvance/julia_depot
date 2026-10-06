#!/usr/bin/env bash
# sysimage.sh `auto` picks the PackageCompiler environment for the running Julia, and
# the sysimage it builds actually loads.
#
# `auto` is what makes the module's sysimage support version-agnostic: the consumer's
# genrule names no version, and the script selects julia/sysimage/v<major>.<minor>/ from
# the Julia that is running. Selecting the WRONG one is not a silent failure, because
# the script then compares that environment's julia_version against the running Julia
# and exits, which is exactly what sysimage_wrong_minor_test.sh checks. So a clean
# build here proves the selection was right, and the two tests together cover both
# branches.
#
# Building is not enough on its own. A sysimage that compiles and then cannot be loaded
# is the failure that costs a deployment, so the image is started and asked to use the
# package that was baked into it.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

sysimage_sh="$(abspath "$1")"
julia_bin="$(abspath "$2")"
manifest="$(abspath "$3")"
stamp="$(abspath "$4")"
sysimage_stamp="$(abspath "$5")"
want_minor="$6"

project="$(copy_project "$manifest" "$TEST_TMPDIR/project")"
src_depot="$(first_depot "$(stamp_value "$stamp" depot)")"

# Both depots instantiate into the ambient depot, so the PackageCompiler environment for
# this minor is in the same tree the project is. If that ever stops being true, `auto`
# would find the environment's files and not its packages, so it is asserted rather
# than assumed.
[ "$(first_depot "$(stamp_value "$sysimage_stamp" depot)")" = "$src_depot" ] ||
    fail "the PackageCompiler environment was instantiated into a different depot than the project"
[ "$(stamp_value "$sysimage_stamp" julia_version)" = "$(stamp_value "$stamp" julia_version)" ] ||
    fail "the PackageCompiler environment was instantiated under a different Julia than the project"

out="$TEST_TMPDIR/sysimage.so"
log="$TEST_TMPDIR/sysimage.log"

# generic, not sysimage.sh's portable default: this tests which environment is chosen, and
# compiling four CPU clones per build ran a CI runner out of memory with the builds in parallel.
env JULIA_DEPOT_BIN="$julia_bin" \
    JULIA_DEPOT_PATH="$(overlay_depot "$src_depot" "$julia_bin")" \
    JULIA_DEPOT_SYSIMAGE_PACKAGES="Crayons" \
    JULIA_DEPOT_SYSIMAGE_CPU_TARGET="generic" \
    "$sysimage_sh" "$project" auto "$out" > "$log" 2>&1 ||
    fail "sysimage.sh auto failed under julia $want_minor:
$(cat "$log")"

# The selection messages are failure paths. Seeing one on a successful run would mean
# the script fell through to a different environment than the assertions below assume.
if grep -qE 'no PackageCompiler environment|was resolved under Julia' "$log"; then
    fail "sysimage.sh auto complained about environment selection:
$(cat "$log")"
fi

[ -f "$out" ] || fail "sysimage.sh auto reported success but wrote no $out"
size="$(stat -c %s "$out")"
[ "$size" -gt 10000000 ] ||
    fail "the sysimage is only $size bytes, which is not an incremental Julia image"

# The real assertion: start Julia on it and use the package that was baked in.
loaded="$(
    env JULIA_DEPOT_PATH="$(overlay_depot "$src_depot" "$julia_bin")" \
        "$julia_bin" --startup-file=no --sysimage "$out" --project="$project" \
        -e 'using Crayons; print(Crayons.Crayon(bold = true) isa Crayons.Crayon)'
)" || fail "julia could not start on the sysimage it just built"
[ "$loaded" = "true" ] ||
    fail "the sysimage loaded but Crayons did not come out of it: got '$loaded'"

echo "PASS: sysimage.sh auto built a $((size / 1024 / 1024)) MiB image on julia $want_minor and it loads"
