#!/usr/bin/env bash
# A julia_depot `hook` used as a test fixture: it stands in for a host's shared depot.
#
# `read_only_depots` is for a depot someone else maintains, such as a host-wide one that already
# holds most of what a Manifest needs. The e2e suite has no such host, so this hook makes one
# before the rule instantiates. It instantiates the same project into the second entry of its
# path (the first read-only depot), using a path of its own on which that depot is first. Seeding
# from the hook orders it before the fetch under test; seeding from another repository would not,
# because Bazel does not order two repositories.
#
# It then records a listing of the shared depot in the first entry, the one the rule writes to.
# tests/read_only_depots_test.sh lists the shared depot again with the same list_depot and
# compares, so anything the rule's instantiate wrote into a read-only depot fails the test. That
# test also checks that packages the shared depot holds were not installed into `dir` again.
set -euo pipefail

# Every entry by path, type and size, then every file's content hash. Timestamps are left out:
# Julia touches a cache file it loads, in whichever depot holds it, so it is tried first next time
# (and ignores the failure where the depot is not writable), so a plain read changes an mtime.
list_depot() {
    (cd "$1" && find . -printf '%P\t%y\t%s\n' | LC_ALL=C sort &&
        find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum)
}

: "${JULIA_DEPOT_BIN:?julia_depot must run the hook with JULIA_DEPOT_BIN set}"
: "${JULIA_DEPOT_PATH:?julia_depot must run the hook with JULIA_DEPOT_PATH set}"

# The depot declares <dir>:<shared>:<absent>:. Any other path is a regression in how the rule
# builds it, and fails the fetch here.
IFS=: read -r -a entries <<<"$JULIA_DEPOT_PATH"
case "$JULIA_DEPOT_PATH" in
    *:) ;;
    *) echo "JULIA_DEPOT_PATH=$JULIA_DEPOT_PATH lost its trailing separator" >&2; exit 1 ;;
esac
[ "${#entries[@]}" -eq 3 ] || {
    echo "JULIA_DEPOT_PATH=$JULIA_DEPOT_PATH should be <dir>:<shared>:<absent>:" >&2
    exit 1
}
dir="${entries[0]}" shared="${entries[1]}"

# Copy the project beside this fixture, because Pkg writes to the project it is given.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project="$(mktemp -d)"
trap 'rm -rf "$project"' EXIT
cp "$here/../projects/v1.12/Project.toml" "$here/../projects/v1.12/Manifest.toml" "$project/"

mkdir -p "$shared"
JULIA_DEPOT_PATH="$shared:" "$JULIA_DEPOT_BIN" --startup-file=no --project="$project" \
    -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'

mkdir -p "$dir/julia_depot_e2e"
list_depot "$shared" > "$dir/julia_depot_e2e/shared_listing.txt"
echo "hook: seeded $shared and recorded its listing in $dir/julia_depot_e2e/shared_listing.txt"
