#!/usr/bin/env bash
# Artifact overrides: the substitution works, and a broken one is caught rather than
# shipped.
#
# An override swaps a locally built native library in for the registry one. It takes two
# files because the path differs between build and image, and the dangerous outcome is
# not a hard failure: if Pkg downloads the registry artifact anyway, the image carries
# BOTH copies and loads the wrong one, silently. So each case is driven end to end.
#
#   correct   the build-time override points at a directory that exists, Pkg skips the
#             download, the hash is absent from the layer, and the IMAGE Overrides.toml
#             is what ships (naming the in-image path, not this machine's)
#   broken    the override points at a directory that does not exist, Pkg downloads the
#             artifact, and the script fails instead of producing that image
#   quoted    the same broken case with the hash written as a quoted TOML key, which is
#             equally valid TOML and must not slip past the check
#
# It also covers the guard on the pair itself: a build-time override with no image-time
# one would ship this host's paths, and is refused before any work happens.
#
# The artifact hash is not hard-coded. It is measured with the module's own
# artifact_paths.jl, which is what a consumer writing an override has to do anyway.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

image_depot="$(abspath "$1")"
artifact_paths="$(abspath "$2")"
julia_bin="$(abspath "$3")"
manifest="$(abspath "$4")"
stamp="$(abspath "$5")"

project="$(copy_project "$manifest" "$TEST_TMPDIR/project")"
src_depot="$(first_depot "$(stamp_value "$stamp" depot)")"

# --- measure the hash to override -------------------------------------------------
paths="$(
    env JULIA_DEPOT_PATH="$(overlay_depot "$src_depot" "$julia_bin")" \
        "$julia_bin" --startup-file=no --project="$project" "$artifact_paths"
)"
[ -n "$paths" ] ||
    fail "artifact_paths.jl found no artifacts for a project that depends on a JLL"
[ "$(printf '%s\n' "$paths" | wc -l)" -eq 1 ] ||
    fail "expected exactly one artifact in this project, got:
$paths"

hash="$(basename "$paths")"
case "$hash" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
    *) fail "artifact_paths.jl printed something that is not an artifact directory: $paths" ;;
esac
[ "${#hash}" -eq 40 ] || fail "expected a 40 character artifact hash, got '$hash'"

# --- the correct override ---------------------------------------------------------
# A stand-in for a locally built bzip2. Its contents do not matter: what matters is that
# the directory exists, because that is what makes Pkg treat the artifact as installed.
local_build="$TEST_TMPDIR/local-bzip2"
mkdir -p "$local_build/lib"
: > "$local_build/lib/libbz2.so.1.0.8"

printf '%s = "%s"\n' "$hash" "$local_build" > "$TEST_TMPDIR/overrides-build.toml"
printf '%s = "%s"\n' "$hash" "/opt/julia-depot/local/bzip2" > "$TEST_TMPDIR/overrides-image.toml"

# The floor goes to zero deliberately: the project's only artifact is the overridden
# one, so a correct build produces an EMPTY artifacts directory, and the default floor
# of one would call that a failure.
env RULES_JULIA_DEPOT_BIN="$julia_bin" \
    JULIA_DEPOT_PATH="$src_depot" \
    RULES_JULIA_DEPOT_CONTENTS=artifacts \
    RULES_JULIA_DEPOT_MIN_ARTIFACTS=0 \
    RULES_JULIA_DEPOT_OVERRIDES_BUILD="$TEST_TMPDIR/overrides-build.toml" \
    RULES_JULIA_DEPOT_OVERRIDES_IMAGE="$TEST_TMPDIR/overrides-image.toml" \
    "$image_depot" "$project" "$TEST_TMPDIR/overridden.tar"

listing="$(tar -tf "$TEST_TMPDIR/overridden.tar")"
# Here-strings rather than pipes: see image_depot_modes_test.sh.
if grep -q "^opt/julia-depot/artifacts/$hash/" <<<"$listing"; then
    fail "artifact $hash was shipped despite being overridden to $local_build"
fi
grep -qx 'opt/julia-depot/artifacts/Overrides.toml' <<<"$listing" ||
    fail "the image Overrides.toml did not ship:
$listing"

shipped="$(tar -xOf "$TEST_TMPDIR/overridden.tar" opt/julia-depot/artifacts/Overrides.toml)"
case "$shipped" in
    *"/opt/julia-depot/local/bzip2"*) ;;
    *) fail "the shipped Overrides.toml is not the image one:
$shipped" ;;
esac
case "$shipped" in
    *"$TEST_TMPDIR"*) fail "the shipped Overrides.toml leaks the build host's path:
$shipped" ;;
esac

# --- the broken override ----------------------------------------------------------
printf '%s = "%s"\n' "$hash" "$TEST_TMPDIR/was-never-built" > "$TEST_TMPDIR/overrides-bad.toml"

rc=0
output="$(
    env RULES_JULIA_DEPOT_BIN="$julia_bin" \
        JULIA_DEPOT_PATH="$src_depot" \
        RULES_JULIA_DEPOT_CONTENTS=artifacts \
        RULES_JULIA_DEPOT_MIN_ARTIFACTS=0 \
        RULES_JULIA_DEPOT_OVERRIDES_BUILD="$TEST_TMPDIR/overrides-bad.toml" \
        RULES_JULIA_DEPOT_OVERRIDES_IMAGE="$TEST_TMPDIR/overrides-image.toml" \
        "$image_depot" "$project" "$TEST_TMPDIR/broken.tar" 2>&1
)" || rc=$?

[ "$rc" -ne 0 ] ||
    fail "an override pointing at a directory that does not exist produced a layer:
$output"
case "$output" in
    *"artifact $hash was downloaded despite the override"*) ;;
    *) fail "the broken override failed, but not with the message that explains it:
$output" ;;
esac

# --- the same break, written as a quoted TOML key ---------------------------------
# A quoted key is the spelling Julia's own documentation uses, and a check that only
# reads bare keys passes this file while silently checking nothing.
printf '"%s" = "%s"\n' "$hash" "$TEST_TMPDIR/was-never-built" > "$TEST_TMPDIR/overrides-quoted.toml"

rc=0
output="$(
    env RULES_JULIA_DEPOT_BIN="$julia_bin" \
        JULIA_DEPOT_PATH="$src_depot" \
        RULES_JULIA_DEPOT_CONTENTS=artifacts \
        RULES_JULIA_DEPOT_MIN_ARTIFACTS=0 \
        RULES_JULIA_DEPOT_OVERRIDES_BUILD="$TEST_TMPDIR/overrides-quoted.toml" \
        RULES_JULIA_DEPOT_OVERRIDES_IMAGE="$TEST_TMPDIR/overrides-image.toml" \
        "$image_depot" "$project" "$TEST_TMPDIR/quoted.tar" 2>&1
)" || rc=$?

[ "$rc" -ne 0 ] ||
    fail "a broken override written as a quoted TOML key was not checked at all:
$output"
case "$output" in
    *"artifact $hash was downloaded despite the override"*) ;;
    *) fail "the quoted-key override failed, but not on the download check:
$output" ;;
esac

# --- an unpaired override is refused up front -------------------------------------
rc=0
output="$(
    env RULES_JULIA_DEPOT_BIN="$julia_bin" \
        JULIA_DEPOT_PATH="$src_depot" \
        RULES_JULIA_DEPOT_OVERRIDES_BUILD="$TEST_TMPDIR/overrides-build.toml" \
        "$image_depot" "$project" "$TEST_TMPDIR/unpaired.tar" 2>&1
)" || rc=$?

[ "$rc" -ne 0 ] ||
    fail "a build-time override with no image-time one produced a layer holding this host's paths"
case "$output" in
    *"RULES_JULIA_DEPOT_OVERRIDES_IMAGE"*) ;;
    *) fail "the unpaired override failed, but not on the pairing guard:
$output" ;;
esac
case "$output" in
    *"instantiating the Manifest"*) fail "the pairing guard fired only after the instantiate it should precede" ;;
esac

echo "PASS: override of $hash was honoured in both TOML spellings, and broken and unpaired ones were caught"
