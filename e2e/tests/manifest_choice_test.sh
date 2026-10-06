#!/usr/bin/env bash
# instantiate.sh must refuse when Julia would instantiate from a different manifest than
# the one the rule pins. A versioned Manifest-v<major>.<minor>.toml beside Manifest.toml
# wins in Julia, so pinning Manifest.toml there would watch and stamp one file while Pkg
# installed from the other.
#
# Then the other way round: pinning the versioned file itself is accepted, which is how a
# project carries one manifest per Julia version.
#
# Last, a manifest with no julia_version (the pre-1.7 format) is refused, since there is
# nothing to check the running Julia against.
#
# Usage: manifest_choice_test.sh <instantiate.sh> <julia> <Manifest.toml> <depot stamp.txt> <minor>
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

instantiate="$(abspath "$1")"
julia_bin="$(abspath "$2")"
manifest="$(abspath "$3")"
stamp="$(abspath "$4")"
minor="$5"

project="$(copy_project "$manifest" "$TEST_TMPDIR/project")"
cp "$project/Manifest.toml" "$project/Manifest-v$minor.toml"
depot="$(overlay_depot "$(first_depot "$(stamp_value "$stamp" depot)")" "$julia_bin")"

rc=0
output="$(
    JULIA_DEPOT_BIN="$julia_bin" JULIA_DEPOT_PATH="$depot" \
        "$instantiate" "$project" "$project/Manifest.toml" "$TEST_TMPDIR/refused.stamp" 2>&1
)" || rc=$?
[ "$rc" -ne 0 ] ||
    fail "instantiate.sh accepted Manifest.toml although Julia uses Manifest-v$minor.toml beside it"
case "$output" in
    *"would instantiate from"*"Manifest-v$minor.toml"*) ;;
    *) fail "instantiate.sh failed, but not with the manifest-choice message:
$output" ;;
esac
[ ! -e "$TEST_TMPDIR/refused.stamp" ] ||
    fail "instantiate.sh wrote a stamp despite refusing the manifest"

JULIA_DEPOT_BIN="$julia_bin" JULIA_DEPOT_PATH="$depot" \
    "$instantiate" "$project" "$project/Manifest-v$minor.toml" "$TEST_TMPDIR/accepted.stamp" ||
    fail "instantiate.sh refused the versioned manifest Julia actually uses"
want_sha="$(sha256sum "$project/Manifest-v$minor.toml" | cut -d' ' -f1)"
[ "$(stamp_value "$TEST_TMPDIR/accepted.stamp" manifest_sha256)" = "$want_sha" ] ||
    fail "the stamp does not hash the versioned manifest"

old="$(copy_project "$manifest" "$TEST_TMPDIR/old_format")"
sed -i '/^julia_version *=/d' "$old/Manifest.toml"
rc=0
output="$(
    JULIA_DEPOT_BIN="$julia_bin" JULIA_DEPOT_PATH="$depot" \
        "$instantiate" "$old" "$old/Manifest.toml" "$TEST_TMPDIR/old.stamp" 2>&1
)" || rc=$?
[ "$rc" -ne 0 ] || fail "instantiate.sh accepted a manifest that records no julia_version"
case "$output" in
    *"records no julia_version"*) ;;
    *) fail "instantiate.sh failed, but not with the missing-julia_version message:
$output" ;;
esac

echo "PASS: the pinned manifest must be the one Julia $minor uses, and must record its julia_version"
