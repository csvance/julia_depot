#!/usr/bin/env bash
# sysimage.sh refuses a PackageCompiler environment resolved under another Julia minor.
#
# PackageCompiler's compat bounds and its precompile cache are both keyed on the Julia
# minor, so an environment pinned for one minor and used under another fails deep inside
# PackageCompiler, minutes into a build, with a message about something else. The script
# checks the pin up front instead. This drives the explicit-project branch, where the
# consumer named the environment rather than saying `auto`, which is the case where
# getting it wrong is possible at all.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

sysimage_sh="$(abspath "$1")"
julia_bin="$(abspath "$2")"
wrong_manifest="$(abspath "$3")"
manifest="$(abspath "$4")"
build_minor="$5"
running_minor="$6"

project="$(copy_project "$manifest" "$TEST_TMPDIR/project")"
build_project="$(dirname "$wrong_manifest")"

rc=0
output="$(
    env JULIA_DEPOT_BIN="$julia_bin" \
        JULIA_DEPOT_PATH="$TEST_TMPDIR/depot" \
        JULIA_DEPOT_SYSIMAGE_PACKAGES="Crayons" \
        "$sysimage_sh" "$project" "$build_project" "$TEST_TMPDIR/sysimage.so" 2>&1
)" || rc=$?

[ "$rc" -ne 0 ] ||
    fail "sysimage.sh accepted a v$build_minor PackageCompiler environment under julia $running_minor"
[ "$rc" -eq 2 ] ||
    fail "expected the pin check to exit 2, got $rc:
$output"
case "$output" in
    *"was resolved under Julia $build_minor but this is Julia $running_minor"*) ;;
    *) fail "sysimage.sh failed, but not on the environment pin:
$output" ;;
esac
[ ! -e "$TEST_TMPDIR/sysimage.so" ] ||
    fail "sysimage.sh wrote an image despite refusing the environment"

# The missing-packages variable is a separate guard, and it has to fire before any of
# the slow work rather than after PackageCompiler has started.
rc=0
output="$(
    env JULIA_DEPOT_BIN="$julia_bin" JULIA_DEPOT_PATH="$TEST_TMPDIR/depot" \
        "$sysimage_sh" "$project" auto "$TEST_TMPDIR/sysimage.so" 2>&1
)" || rc=$?
[ "$rc" -ne 0 ] || fail "sysimage.sh ran with no JULIA_DEPOT_SYSIMAGE_PACKAGES set"
case "$output" in
    *JULIA_DEPOT_SYSIMAGE_PACKAGES*) ;;
    *) fail "the missing-packages failure does not name the variable:
$output" ;;
esac

# The same run with only the pre-0.1.1 spellings, RULES_JULIA_DEPOT_*: still honoured, each
# with a deprecation warning, and refused for the same reason.
rc=0
output="$(
    env -u JULIA_DEPOT_BIN -u JULIA_DEPOT_SYSIMAGE_PACKAGES \
        RULES_JULIA_DEPOT_BIN="$julia_bin" \
        JULIA_DEPOT_PATH="$TEST_TMPDIR/depot" \
        RULES_JULIA_DEPOT_SYSIMAGE_PACKAGES="Crayons" \
        "$sysimage_sh" "$project" "$build_project" "$TEST_TMPDIR/sysimage.so" 2>&1
)" || rc=$?
[ "$rc" -eq 2 ] ||
    fail "with the deprecated spellings, expected the pin check to exit 2, got $rc:
$output"
for name in BIN SYSIMAGE_PACKAGES; do
    case "$output" in
        *"RULES_JULIA_DEPOT_$name is deprecated; set JULIA_DEPOT_$name instead"*) ;;
        *) fail "no deprecation warning for RULES_JULIA_DEPOT_$name:
$output" ;;
    esac
done

echo "PASS: a v$build_minor environment under julia $running_minor was refused, exit 2", also under the deprecated spellings
