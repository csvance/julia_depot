#!/usr/bin/env bash
# A julia.depot with `project` fails its fetch, naming what is missing, instead of instantiating an
# environment that quietly lacks part of the project.
#
# Usage: project_srcs_test.sh <instantiate.sh> <julia> <Project.toml> <member Project.toml>
#            <member source> <lock> <depot stamp.txt>
#
# The fetch stages `project`, `project_srcs` and the lock into a tree and runs instantiate.sh
# there; this test builds such trees by hand. Pkg.instantiate succeeds without a workspace member
# and says nothing, and Pkg.precompile skips a path package with no source and reports success,
# so both are checked before Pkg is reached. The staged tree is the real one, the member present,
# for a run that must succeed.
#
# `precompile = False` must mean no precompiling at all. Pkg.instantiate precompiles on its own
# after installing anything, so that run uses an empty depot, where it installs everything, and
# must leave no compiled/. With the member's source present, as in place it is, and precompile
# on, the caches must appear, so turning that off cannot have turned precompiling off with it.
# Network: the two runs on an empty depot download the project's packages.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

instantiate="$(abspath "$1")"
julia_bin="$(abspath "$2")"
project="$(abspath "$3")"
member="$(abspath "$4")"
member_src="$(abspath "$5")"
lock="$(abspath "$6")"
stamp="$(abspath "$7")"
depot="$(overlay_depot "$(first_depot "$(stamp_value "$stamp" depot)")" "$julia_bin")"

# stage <dir> [with-member]: the tree the fetch would stage.
stage() {
    mkdir -p "$1"
    cp -L "$project" "$1/Project.toml"
    cp -L "$lock" "$1/Manifest.toml"
    if [ "${2:-}" = with-member ]; then
        mkdir -p "$1/packages/WsMember"
        cp -L "$member" "$1/packages/WsMember/Project.toml"
    fi
    chmod -R u+w "$1"
}

# run <tree> <yes|no> [<depot path>]
run() {
    env JULIA_DEPOT_BIN="$julia_bin" JULIA_DEPOT_PATH="${3:-$depot}" \
        "$instantiate" "$1" "$1/Manifest.toml" "$TEST_TMPDIR/stamp.txt" "$2" 2>&1
}

# An empty depot of the test's own, with the bundled ones behind it for the stdlib caches.
empty_depot() {
    mkdir -p "$TEST_TMPDIR/$1"
    printf '%s:%s\n' "$TEST_TMPDIR/$1" "$(bundled_depots "$julia_bin")"
}

# The member left off project_srcs.
stage "$TEST_TMPDIR/no-member"
rc=0
output="$(run "$TEST_TMPDIR/no-member" no)" || rc=$?
[ "$rc" -ne 0 ] || fail "a project missing its workspace member instantiated:
$output"
case "$output" in
    *"packages/WsMember/Project.toml"*"project_srcs"*) ;;
    *) fail "the missing member failed, but without naming it and project_srcs:
$output" ;;
esac

# Precompiling a staged project, whose path package has no source.
stage "$TEST_TMPDIR/precompile" with-member
rc=0
output="$(run "$TEST_TMPDIR/precompile" yes)" || rc=$?
[ "$rc" -ne 0 ] || fail "precompiling a staged project with a path package and no source succeeded:
$output"
case "$output" in
    *"WsMember"*"precompile = False"*) ;;
    *) fail "precompiling without the source failed, but without naming the package and precompile = False:
$output" ;;
esac

# The tree as the fetch stages it, with precompile off, as the workspace depot declares, into an
# empty depot: everything is installed, and nothing may be precompiled.
stage "$TEST_TMPDIR/ok" with-member
output="$(run "$TEST_TMPDIR/ok" no "$(empty_depot no-precompile)")" ||
    fail "the staged project with its member did not instantiate:
$output"
[ ! -e "$TEST_TMPDIR/no-precompile/compiled" ] ||
    fail "precompile off, yet the depot gained compiled/: $(ls "$TEST_TMPDIR/no-precompile/compiled"/*)
$output"
case "$output" in
    *Precompiling*) fail "precompile off, yet the fetch precompiled:
$output" ;;
esac

# The member's source present, as for a depot instantiated in place, and precompile on.
stage "$TEST_TMPDIR/with-src" with-member
mkdir -p "$TEST_TMPDIR/with-src/packages/WsMember/src"
cp -L "$member_src" "$TEST_TMPDIR/with-src/packages/WsMember/src/"
output="$(run "$TEST_TMPDIR/with-src" yes "$(empty_depot precompile)")" ||
    fail "the project with its member's source did not instantiate and precompile:
$output"
for pkg in Crayons WsMember; do
    [ -d "$TEST_TMPDIR/precompile/compiled/v$("$julia_bin" --startup-file=no -e 'print(VERSION.major, ".", VERSION.minor)')/$pkg" ] ||
        fail "precompile on, yet $pkg has no cache in the depot:
$output"
done

echo "PASS: a missing member and a precompile without sources each fail naming the fix, precompile off precompiles nothing, and precompile on precompiles the project"
