#!/usr/bin/env bash
# sysimage.sh installs its own PackageCompiler environment into a depot that lacks it.
#
# Every other sysimage test runs on a depot already filled by a `julia.depot` over the module's
# PackageCompiler environment, so none can tell whether sysimage.sh works without it. A consumer
# following docs/src/recipes.md declares no such depot, and on a fresh depot the script used to
# fail inside `using PackageCompiler`.
#
# The depot is empty and owned by this test, with only the distribution's bundled depots behind
# it. Layering it over a shared depot would let PackageCompiler be found there, and the test would
# pass without exercising the install. For the same reason it asserts that the install line was
# printed and that PackageCompiler is in this depot, instead of inferring both from a successful
# build.
#
# Network: the project, the General registry and PackageCompiler are all downloaded.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

sysimage_sh="$(abspath "$1")"
julia_bin="$(abspath "$2")"
manifest="$(abspath "$3")"

project="$(copy_project "$manifest" "$TEST_TMPDIR/project")"
depot="$TEST_TMPDIR/fresh-depot"
mkdir -p "$depot"
export JULIA_DEPOT_PATH="$depot:$(bundled_depots "$julia_bin")"

# Install the project's own packages, as julia.depot would. Check that PackageCompiler is not
# among them.
"$julia_bin" --startup-file=no --project="$project" -e 'using Pkg; Pkg.instantiate()' \
    > "$TEST_TMPDIR/project.log" 2>&1 ||
    fail "could not instantiate the project into the fresh depot:
$(cat "$TEST_TMPDIR/project.log")"
[ ! -e "$depot/packages/PackageCompiler" ] ||
    fail "PackageCompiler is already in the fresh depot, so this test would prove nothing"

out="$TEST_TMPDIR/sysimage.so"
log="$TEST_TMPDIR/sysimage.log"
# CPU target generic instead of sysimage.sh's portable default: this test is about installing the
# environment, and compiling four CPU clones per build, with builds in parallel, ran a CI runner
# out of memory.
env JULIA_DEPOT_BIN="$julia_bin" JULIA_DEPOT_SYSIMAGE_PACKAGES="Crayons" \
    JULIA_DEPOT_SYSIMAGE_CPU_TARGET="generic" \
    "$sysimage_sh" "$project" auto "$out" > "$log" 2>&1 ||
    fail "sysimage.sh auto failed on a depot without PackageCompiler:
$(cat "$log")"

grep -q 'installing the PackageCompiler environment' "$log" ||
    fail "sysimage.sh succeeded without installing PackageCompiler, so it came from somewhere other than this depot:
$(cat "$log")"
[ -d "$depot/packages/PackageCompiler" ] ||
    fail "sysimage.sh reported installing PackageCompiler but it is not in $depot/packages"
[ -f "$out" ] || fail "sysimage.sh reported success but wrote no $out"

loaded="$(
    "$julia_bin" --startup-file=no --sysimage "$out" --project="$project" \
        -e 'using Crayons; print(Crayons.Crayon(bold = true) isa Crayons.Crayon)'
)" || fail "julia could not start on the sysimage it just built"
[ "$loaded" = "true" ] ||
    fail "the sysimage loaded but Crayons did not come out of it: got '$loaded'"

echo "PASS: sysimage.sh installed PackageCompiler into a fresh depot and built an image that loads"
