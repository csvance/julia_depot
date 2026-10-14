#!/usr/bin/env bash
# A julia.depot fetched with an ambient JULIA_DEPOT_PATH that leaves out Julia's bundled depots
# prints a warning, and one that keeps them does not.
#
# Usage: e2e/bundled_warning_test.sh   (from anywhere; runs Bazel in e2e/)
#
# Without the bundled depots every fetch recompiles Pkg and the other stdlibs into the depot. The
# rule cannot tell whether that was meant, so it warns instead of changing the path. The warning
# is printed during a fetch, which a test action cannot run, so this script drives Bazel from
# outside, like refetch_test.sh. It fetches bundled_warning_1_13, whose hook fails the fetch
# before instantiate: the warning comes before the hook, so each fetch takes seconds and the
# failure is expected.
set -euo pipefail

e2e="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
warning="leaves out Julia's bundled depots"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

depot="$(mktemp -d)"
trap 'rm -rf "$depot"' EXIT

# fetch <JULIA_DEPOT_PATH>: the output of a fetch that the hook must have stopped.
fetch() {
    local out rc=0
    out="$(cd "$e2e" && bazel fetch --repo_env=JULIA_DEPOT_PATH="$1" @bundled_warning_1_13 2>&1)" || rc=$?
    [ "$rc" -ne 0 ] && grep -q "stop_hook: stopping the fetch" <<<"$out" ||
        fail "JULIA_DEPOT_PATH=$1: the fetch did not stop in the hook:
$out"
    printf '%s\n' "$out"
}

grep -q "$warning" <<<"$(fetch "$depot")" ||
    fail "JULIA_DEPOT_PATH=$depot names no bundled depot, and the fetch did not warn"

# The distribution's share/julia, named rather than reached through an empty entry.
dist="$(cd "$e2e" && bazel info output_base 2>/dev/null)/external/julia_depot++julia+julia_1_13"
[ -x "$dist/bin/julia" ] || fail "no Julia 1.13 distribution at $dist"

for kept in "$depot:" ":$depot" "$depot::/nonexistent" "$depot:$dist/share/julia"; do
    if grep -q "$warning" <<<"$(fetch "$kept")"; then
        fail "JULIA_DEPOT_PATH=$kept keeps the bundled depots, and the fetch warned anyway"
    fi
done

echo "PASS: the fetch warned for a depot path without the bundled depots, and only then"
