#!/usr/bin/env bash
# image_depot.sh builds a layer holding exactly what each mode promises.
#
# `artifacts` is for an image whose code comes from a sysimage, so the layer carries
# native libraries and nothing else. `full` is for an image with no sysimage, which
# loads its packages from source and therefore needs packages/ too. The difference
# between them is the entire reason the switch exists, so both are listed and compared.
#
# The layer is also checked for what must never be in it. The script copies the source
# depot's servers/ into its clean depot so a private package server resolves the way the
# developer's does, and servers/ holds credentials. Those exist during the build and must
# not leave it.
#
# Listings are searched as here-strings, never piped: under pipefail, `printf | grep -q`
# fails whenever grep matches and exits before printf has written the rest, which a loaded
# CI runner does often enough to fail a layer that is correct.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

image_depot="$(abspath "$1")"
julia_bin="$(abspath "$2")"
manifest="$(abspath "$3")"
stamp="$(abspath "$4")"

project="$(copy_project "$manifest" "$TEST_TMPDIR/project")"
src_depot="$(first_depot "$(stamp_value "$stamp" depot)")"

build_layer() {
    local contents="$1" out="$2"
    shift 2
    env JULIA_BIN="$julia_bin" \
        JULIA_DEPOT_PATH="$src_depot" \
        JULIA_DEPOT_CONTENTS="$contents" \
        "$@" \
        "$image_depot" "$project" "$out"
}

assert_no_secrets() {
    local listing="$1"
    if grep -qE '(^|/)(servers|registries)/' <<<"$listing"; then
        fail "the layer carries depot state that is not artifacts or packages:
$(grep -E '(^|/)(servers|registries)/' <<<"$listing")"
    fi
}

# --- artifacts mode ---------------------------------------------------------------
build_layer artifacts "$TEST_TMPDIR/artifacts.tar"
artifacts_listing="$(tar -tf "$TEST_TMPDIR/artifacts.tar")"

hash_dirs="$(printf '%s\n' "$artifacts_listing" |
    sed -nE 's#^opt/julia-depot/artifacts/([0-9a-f]{40})/.*#\1#p' | sort -u)"
[ -n "$hash_dirs" ] ||
    fail "no opt/julia-depot/artifacts/<hash>/ in the artifacts-mode layer:
$artifacts_listing"

# The one JLL in the project is Bzip2_jll, so its native library is what an image would
# actually be missing if the artifact selection silently came up empty.
grep -qE '^opt/julia-depot/artifacts/[0-9a-f]{40}/.*libbz2' <<<"$artifacts_listing" ||
    fail "the artifact layer has no libbz2 under it:
$artifacts_listing"

if grep -q '^opt/julia-depot/packages/' <<<"$artifacts_listing"; then
    fail "artifacts mode shipped packages/, which is the whole difference from full mode"
fi
assert_no_secrets "$artifacts_listing"

# --- full mode --------------------------------------------------------------------
build_layer full "$TEST_TMPDIR/full.tar"
full_listing="$(tar -tf "$TEST_TMPDIR/full.tar")"

grep -q '^opt/julia-depot/packages/' <<<"$full_listing" ||
    fail "full mode shipped no packages/:
$full_listing"
grep -qE '^opt/julia-depot/packages/Crayons/' <<<"$full_listing" ||
    fail "full mode shipped packages/ without the project's own packages in it"
grep -qE '^opt/julia-depot/artifacts/[0-9a-f]{40}/' <<<"$full_listing" ||
    fail "full mode dropped the artifacts the artifacts mode found"
assert_no_secrets "$full_listing"

# --- the prefix is configurable ---------------------------------------------------
build_layer artifacts "$TEST_TMPDIR/prefixed.tar" JULIA_DEPOT_IMAGE_PREFIX=srv/depot
prefixed_listing="$(tar -tf "$TEST_TMPDIR/prefixed.tar")"
grep -qE '^srv/depot/artifacts/[0-9a-f]{40}/' <<<"$prefixed_listing" ||
    fail "JULIA_DEPOT_IMAGE_PREFIX was ignored:
$(head <<<"$prefixed_listing")"

# --- the artifact floor is a real floor -------------------------------------------
rc=0
output="$(build_layer artifacts "$TEST_TMPDIR/floor.tar" JULIA_DEPOT_MIN_ARTIFACTS=9999 2>&1)" || rc=$?
[ "$rc" -ne 0 ] ||
    fail "JULIA_DEPOT_MIN_ARTIFACTS=9999 was satisfied by a two-package project"
case "$output" in
    *"below JULIA_DEPOT_MIN_ARTIFACTS"*) ;;
    *) fail "the artifact floor failed with the wrong message:
$output" ;;
esac

echo "PASS: artifacts mode shipped $(printf '%s\n' "$hash_dirs" | wc -l) artifact(s) and no packages, full mode shipped both"
