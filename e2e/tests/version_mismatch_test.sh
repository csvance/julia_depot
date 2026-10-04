#!/usr/bin/env bash
# instantiate.sh REFUSES a Manifest resolved under a different Julia.
#
# This is the guarantee the whole module is built around, and it is the one failure that
# is invisible if it does not fire: a Manifest resolved under another Julia instantiates
# happily and then behaves differently at run time. So the test runs the script directly,
# with a real Julia and a real Manifest that disagree, and insists on three things: a
# non-zero exit, the message that names both versions, and no stamp file, since a stamp
# is the module's claim that an environment is good.
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

# A depot behind a writable overlay, only so Julia has somewhere to find an already
# precompiled Pkg instead of building one for a test that fails three lines in.
depot="$(overlay_depot "$(first_depot "$(stamp_value "$stamp" depot)")" "$julia_bin")"

rc=0
output="$(
    RULES_JULIA_DEPOT_BIN="$julia_bin" JULIA_DEPOT_PATH="$depot" \
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
