#!/usr/bin/env bash
# A julia_depot `hook` used as a test fixture.
#
# A real hook arranges depot state that Pkg.instantiate needs, such as a private registry cloned
# into the depot or a package-server credential written to servers/. It must run at fetch time,
# before instantiate. To test that ordering, this hook leaves evidence instantiate cannot have
# written: a marker in the depot holding the value of the variable the depot named in
# `hook_environ`. tests/hook_test.sh checks that the marker exists (the hook ran), holds the
# expected value (`hook_environ` was passed), and is not newer than the stamp instantiate wrote
# afterwards (the ordering).
#
# It also asserts JULIA_DEPOT_BIN and JULIA_DEPOT_PATH, which the rule documents as passing, so a
# regression fails the fetch.
set -euo pipefail

: "${JULIA_DEPOT_BIN:?julia_depot must run the hook with JULIA_DEPOT_BIN set}"

: "${E2E_HOOK_VALUE:?this hook is declared with hook_environ = [\"E2E_HOOK_VALUE\"]}"

# The rule always passes JULIA_DEPOT_PATH, the value env.sh exports and stamp.txt records, even
# when the launching environment set none. Required with no default, so a regression fails the
# fetch here.
: "${JULIA_DEPOT_PATH:?julia_depot must run the hook with JULIA_DEPOT_PATH set}"
depot="${JULIA_DEPOT_PATH%%:*}"

# The marker is keyed on the Julia version, so that a marker can never be read against another
# version's stamp, even if two versions' hooked depots ever share a directory. Asking JULIA_DEPOT_BIN for the
# version also proves the rule passed a Julia that runs.
version="$("$JULIA_DEPOT_BIN" --startup-file=no -e 'print(VERSION)')"

dir="$depot/julia_depot_e2e"
mkdir -p "$dir"
printf '%s\n' "$E2E_HOOK_VALUE" > "$dir/hook_marker_$version.txt"
echo "hook: wrote $dir/hook_marker_$version.txt"
