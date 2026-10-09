#!/usr/bin/env bash
# The depot `hook` ran, received its `hook_environ`, and ran before instantiate.
#
# A hook puts something in the depot that Pkg.instantiate needs, such as a private registry or a
# package-server credential. A hook that runs afterwards fails only on the first machine without a
# warm depot. The fixture writes a marker at hook time, the rule writes stamp.txt at instantiate
# time, and this test compares them.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

stamp="$(abspath "$1")"
env_sh="$(abspath "$2")"
want_value="$3"

[ -s "$env_sh" ] || fail "the hooked depot produced no env.sh"

depot="$(first_depot "$(stamp_value "$stamp" depot)")"

# One marker per Julia version: every version in the matrix has a hooked depot in this shared
# depot, so with one filename they would overwrite each other and this test would compare one
# version's marker against another version's stamp.
marker="$depot/julia_depot_e2e/hook_marker_$(stamp_value "$stamp" julia_version).txt"

[ -f "$marker" ] ||
    fail "no $marker: the hook did not run, or it ran against a different depot than instantiate did"

got="$(cat "$marker")"
[ "$got" = "$want_value" ] ||
    fail "the hook recorded '$got' but hook_environ should have passed '$want_value'"

# instantiate.sh writes the stamp after it returns, so a marker newer than the stamp
# means the hook ran second.
if [ "$marker" -nt "$stamp" ]; then
    fail "the hook marker is newer than stamp.txt, so the hook ran after instantiate:
marker $(stat -c %y "$marker")
stamp  $(stat -c %y "$stamp")"
fi

echo "PASS: the hook ran before instantiate and read E2E_HOOK_VALUE=$got"
