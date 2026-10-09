#!/usr/bin/env bash
# A julia.depot with `project` fails its fetch, naming what is missing, instead of instantiating an
# environment that quietly lacks part of the project.
#
# Usage: project_srcs_test.sh <instantiate.sh> <julia> <Project.toml> <member Project.toml>
#            <lock> <depot stamp.txt>
#
# The fetch stages `project`, `project_srcs` and the lock into a tree and runs instantiate.sh
# there; this test builds such trees by hand. Pkg.instantiate succeeds without a workspace member
# and says nothing, and Pkg.precompile skips a path package with no source and reports success,
# so both are checked before Pkg is reached. The staged tree is the real one, the member present,
# for a run that must succeed.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

instantiate="$(abspath "$1")"
julia_bin="$(abspath "$2")"
project="$(abspath "$3")"
member="$(abspath "$4")"
lock="$(abspath "$5")"
stamp="$(abspath "$6")"
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

run() {
    env JULIA_DEPOT_BIN="$julia_bin" JULIA_DEPOT_PATH="$depot" \
        "$instantiate" "$1" "$1/Manifest.toml" "$TEST_TMPDIR/stamp.txt" "$2" 2>&1
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

# The tree as the fetch stages it, with precompile off, as the workspace depot declares.
stage "$TEST_TMPDIR/ok" with-member
output="$(run "$TEST_TMPDIR/ok" no)" || fail "the staged project with its member did not instantiate:
$output"

echo "PASS: a missing member and a precompile without sources each fail naming the fix, and the full staged project instantiates"
