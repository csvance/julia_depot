#!/usr/bin/env bash
# instantiate.sh refuses a Manifest resolved under a different Julia.
#
# This is the module's central guarantee, and its failure is invisible if the check does not
# fire: a Manifest resolved under another Julia instantiates without error and then behaves
# differently at run time. The test runs the script directly with a real Julia and a real
# Manifest that disagree, and requires a non-zero exit, a message naming both versions, and no
# stamp file, since a stamp is the module's claim that an environment is good.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

instantiate="$(abspath "$1")"
julia_bin="$(abspath "$2")"
manifest="$(abspath "$3")"
stamp="$(abspath "$4")"
manifest_version="$5"
running_version="$6"

project="$(copy_project "$manifest" "$TEST_TMPDIR/project")"
stamp_out="$TEST_TMPDIR/stamp.out"

# A writable overlay over the fetched depot, so Julia finds an already precompiled Pkg instead
# of building one for a test that fails early.
depot="$(overlay_depot "$(first_depot "$(stamp_value "$stamp" depot)")" "$julia_bin")"

rc=0
output="$(
    JULIA_DEPOT_BIN="$julia_bin" JULIA_DEPOT_PATH="$depot" \
        "$instantiate" "$project" "$project/Manifest.toml" "$stamp_out" 2>&1
)" || rc=$?

[ "$rc" -ne 0 ] ||
    fail "instantiate.sh accepted a Manifest resolved under Julia $manifest_version while running Julia $running_version"

case "$output" in
    *"was resolved under Julia $manifest_version but this is Julia $running_version"*) ;;
    *) fail "instantiate.sh failed, but not with the version-mismatch message:
$output" ;;
esac

[ ! -e "$stamp_out" ] ||
    fail "instantiate.sh wrote a stamp despite refusing the manifest"

echo "PASS: a $manifest_version manifest under julia $running_version was refused, exit $rc"
