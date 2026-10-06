#!/usr/bin/env bash
# A julia_depot `hook`, as a test fixture.
#
# The real use of a hook is arranging depot state that Pkg.instantiate then needs: a
# private registry cloned into the depot, a package-server credential written to
# servers/. That has to happen at fetch time and before instantiate, and the only way to
# test "before" is to leave evidence behind that instantiate cannot have written.
#
# So this one writes a marker into the depot, containing the value of the variable the
# depot named in `hook_environ`. tests/hook_test.sh then checks three things: the marker
# exists (the hook ran), it holds the expected value (hook_environ came through), and it
# is not newer than the stamp instantiate wrote afterwards (the ordering).
#
# It also asserts the two variables the rule documents itself as passing, so a
# regression there fails the fetch rather than going unnoticed.
set -euo pipefail

: "${JULIA_DEPOT_BIN:?julia_depot must run the hook with JULIA_DEPOT_BIN set}"

# The pre-0.1.1 name, still given (deprecated) so existing hooks keep working.
[ "${RULES_JULIA_DEPOT_BIN:-}" = "$JULIA_DEPOT_BIN" ] || {
    echo "julia_depot must still give the hook RULES_JULIA_DEPOT_BIN, equal to JULIA_DEPOT_BIN" >&2
    exit 1
}
: "${E2E_HOOK_VALUE:?this hook is declared with hook_environ = [\"E2E_HOOK_VALUE\"]}"

# The depot rule always hands the hook JULIA_DEPOT_PATH, the same value env.sh exports and
# stamp.txt records, even when the launching environment set none. Required, not
# defaulted, so a regression fails the fetch here.
: "${JULIA_DEPOT_PATH:?julia_depot must run the hook with JULIA_DEPOT_PATH set}"
depot="${JULIA_DEPOT_PATH%%:*}"

# The marker is keyed on the Julia version, because every version in the matrix has a
# hooked depot and they all share this ambient depot: one filename would mean the last
# fetch overwrote the others, and the ordering check in the test would then be comparing
# a marker against another version's stamp. Asking JULIA_DEPOT_BIN for the version also proves
# the rule handed over a Julia that runs, not just a variable that is set.
version="$("$JULIA_DEPOT_BIN" --startup-file=no -e 'print(VERSION)')"

dir="$depot/julia_depot_e2e"
mkdir -p "$dir"
printf '%s\n' "$E2E_HOOK_VALUE" > "$dir/hook_marker_$version.txt"
echo "hook: wrote $dir/hook_marker_$version.txt"
