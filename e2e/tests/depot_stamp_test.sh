#!/usr/bin/env bash
# julia.depot fetched and produced its two output files, env.sh and stamp.txt.
#
# The depot is a keyed side effect on a directory Bazel does not track, so env.sh and stamp.txt are
# the only evidence a consumer or a person gets. This checks that they record what the fetch did:
# the Julia that ran, the pinned Manifest, the host, and the depot. It also checks that env.sh
# names no julia binary, which would put a machine-specific absolute path into every downstream
# action key.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

env_sh="$(abspath "$1")"
stamp="$(abspath "$2")"
manifest="$(abspath "$3")"
want_version="$4"
# Optional: what the exported depot path must end with, for a depot whose location the test
# cannot compute because it was decided at fetch time.
want_suffix="${5:-}"

[ -s "$stamp" ] || fail "stamp.txt is empty or missing"

# Consumers source env.sh, so it must be valid shell even when nearly empty, as it is whenever
# the launching environment set no JULIA_DEPOT_PATH.
(
    set -euo pipefail
    # shellcheck disable=SC1090
    . "$env_sh"
) || fail "env.sh is not sourceable"

if grep -qE 'JULIA_DEPOT_BIN|/bin/julia' "$env_sh"; then
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

# env.sh must export the depot path the stamp records, or a consumer sourcing it would use a
# different depot than the one the fetch filled.
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
case "$exported" in
    *"$want_suffix") ;;
    *) fail "env.sh exports JULIA_DEPOT_PATH=$exported, which does not end in $want_suffix" ;;
esac

# Without a suffix, the depot has a declared `dir` and must not reach the user depot: on Julia
# 1.10 a trailing separator would put ~/.julia behind `dir`. A suffix already pins the path's end.
if [ -z "$want_suffix" ]; then
    IFS=: read -r -a entries <<<"$exported"
    for e in "${entries[@]}"; do
        case "$e" in
            */.julia) fail "env.sh exports JULIA_DEPOT_PATH=$exported, which reaches the user depot $e" ;;
        esac
    done
fi

echo "PASS: depot stamped julia $got_version, manifest $got_sha, depot $depot"
