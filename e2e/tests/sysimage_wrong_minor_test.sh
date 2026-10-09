#!/usr/bin/env bash
# sysimage.sh refuses a PackageCompiler environment resolved under another Julia minor.
#
# PackageCompiler's compat bounds and its precompile cache are both keyed on the Julia minor, so an
# environment pinned for one minor and used under another fails deep inside PackageCompiler,
# minutes into a build, with an unrelated message. The script checks the pin up front. This test
# drives the explicit-project branch, where the consumer names the environment instead of using
# `auto`; only that branch can get the minor wrong.
#
# It also checks the guards that run before any slow work: a missing package list, and a
# missing or unusable JULIA_DEPOT_SYSIMAGE_CC. The pin check runs with the compiler set to
# `system`, since it fails before anything is linked.
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
        JULIA_DEPOT_SYSIMAGE_CC=system \
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

# The missing-packages guard is separate, and must fire before any slow work starts.
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

# No compiler configured: the script refuses rather than picking the host's, and names the
# variable and each of its three kinds of value.
rc=0
output="$(
    env -u JULIA_DEPOT_SYSIMAGE_CC JULIA_DEPOT_BIN="$julia_bin" JULIA_DEPOT_PATH="$TEST_TMPDIR/depot" \
        JULIA_DEPOT_SYSIMAGE_PACKAGES="Crayons" \
        "$sysimage_sh" "$project" auto "$TEST_TMPDIR/sysimage.so" 2>&1
)" || rc=$?
[ "$rc" -eq 2 ] || fail "with no JULIA_DEPOT_SYSIMAGE_CC, expected exit 2, got $rc:
$output"
for want in "set JULIA_DEPOT_SYSIMAGE_CC" "@julia_depot_cc//:bin/cc" "your own compiler" "system"; do
    case "$output" in
        *"$want"*) ;;
        *) fail "the missing-compiler failure does not mention '$want':
$output" ;;
    esac
done

# A compiler path that is not an executable file.
rc=0
output="$(
    env JULIA_DEPOT_BIN="$julia_bin" JULIA_DEPOT_PATH="$TEST_TMPDIR/depot" \
        JULIA_DEPOT_SYSIMAGE_PACKAGES="Crayons" JULIA_DEPOT_SYSIMAGE_CC="$TEST_TMPDIR/no-such-cc" \
        "$sysimage_sh" "$project" auto "$TEST_TMPDIR/sysimage.so" 2>&1
)" || rc=$?
[ "$rc" -eq 2 ] || fail "with a missing compiler path, expected exit 2, got $rc:
$output"
case "$output" in
    *"JULIA_DEPOT_SYSIMAGE_CC=$TEST_TMPDIR/no-such-cc is not an executable file"*) ;;
    *) fail "the bad compiler path failure does not name the path:
$output" ;;
esac
[ ! -e "$TEST_TMPDIR/sysimage.so" ] ||
    fail "sysimage.sh wrote an image despite refusing its compiler"

echo "PASS: a v$build_minor environment under julia $running_minor was refused, exit 2, as were a missing package list and a missing or unusable compiler"
