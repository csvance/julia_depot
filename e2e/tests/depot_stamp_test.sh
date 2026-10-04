#!/usr/bin/env bash
# julia.depot fetched successfully and produced the two files that ARE its output.
#
# The depot itself is a keyed side effect on a directory Bazel does not track, so
# env.sh and stamp.txt are the only evidence a consumer or a human gets. This checks
# that they say what the fetch actually did: the Julia that ran, the Manifest that was
# pinned, the host, and the depot it landed in. It also checks what env.sh must NOT
# contain, since a julia path baked into it would put a machine-specific absolute path
# into every downstream action key.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

env_sh="$(abspath "$1")"
stamp="$(abspath "$2")"
manifest="$(abspath "$3")"
want_version="$4"

[ -s "$stamp" ] || fail "stamp.txt is empty or missing"

# env.sh is sourced by consumers, so it has to be valid shell even when it is nearly
# empty, which is the case whenever the launching environment set no JULIA_DEPOT_PATH.
(
    set -euo pipefail
    # shellcheck disable=SC1090
    . "$env_sh"
) || fail "env.sh is not sourceable"

if grep -qE 'RULES_JULIA_DEPOT_BIN|/bin/julia' "$env_sh"; then
    fail "env.sh names a julia binary; consumers take Julia as a label, not from here:
$(cat "$env_sh")"
fi

got_version="$(stamp_value "$stamp" julia_version)"
[ "$got_version" = "$want_version" ] ||
    fail "stamp says julia_version=$got_version, expected $want_version"

want_sha="$(sha256sum "$manifest" | cut -d' ' -f1)"
got_sha="$(stamp_value "$stamp" manifest_sha256)"
[ "$got_sha" = "$want_sha" ] ||
    fail "stamp says manifest_sha256=$got_sha but the manifest hashes to $want_sha"

triplet="$(stamp_value "$stamp" host_triplet)"
case "$triplet" in
    *linux*) ;;
    *) fail "host_triplet=$triplet does not look like a Linux triplet" ;;
esac

depot="$(first_depot "$(stamp_value "$stamp" depot)")"
[ -d "$depot" ] || fail "stamp says depot=$depot but that is not a directory"
[ -d "$depot/packages" ] ||
    fail "$depot has no packages/; the fetch cannot have instantiated anything"

# When the fetch saw a JULIA_DEPOT_PATH, env.sh has to hand the same one back, or a
# consumer sourcing it would run against a different depot than the one just filled.
exported="$(
    # shellcheck disable=SC1090
    . "$env_sh"
    printf '%s\n' "${JULIA_DEPOT_PATH:-}"
)"
[ -n "$exported" ] ||
    fail "env.sh does not export JULIA_DEPOT_PATH; it must, even when the fetch environment set none:
$(cat "$env_sh")"
[ "$exported" = "$(stamp_value "$stamp" depot)" ] ||
    fail "env.sh exports JULIA_DEPOT_PATH=$exported but the stamp says $(stamp_value "$stamp" depot)"

echo "PASS: depot stamped julia $got_version, manifest $got_sha, depot $depot"
