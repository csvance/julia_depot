#!/usr/bin/env bash
# A julia_depot `hook` that stands in for a host's shared depot, as a test fixture.
#
# read_only_depots exists for a depot someone else maintains: a host-wide one that already
# holds most of what a Manifest needs. The e2e suite has no such host, so this hook makes
# one before the rule instantiates: it instantiates the same project into the SECOND entry of
# the path it is given, the first read-only depot, through a path of its own on which that
# depot is the first entry. Seeding from the hook rather than from another repository is
# what orders it before the fetch under test; Bazel gives two repositories no order.
#
# Then it records a listing of the shared depot in the first entry, the one the rule writes
# to. tests/read_only_depots_test.sh lists it again with the same list_depot and compares, so
# anything the rule's own instantiate wrote into a read-only depot fails the test, and checks
# that the packages the shared depot holds were not installed into `dir` a second time.
set -euo pipefail

# Every entry by path, type and size, then every file's content hash, without timestamps: Julia
# touches a cache file it loads, in whichever depot holds it, to try it first next time (and
# ignores the failure where it may not), so an mtime changes on a plain read.
list_depot() {
    (cd "$1" && find . -printf '%P\t%y\t%s\n' | LC_ALL=C sort &&
        find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum)
}

: "${JULIA_DEPOT_BIN:?julia_depot must run the hook with JULIA_DEPOT_BIN set}"
: "${JULIA_DEPOT_PATH:?julia_depot must run the hook with JULIA_DEPOT_PATH set}"

# <dir>:<shared>:<absent>: is what the depot declares; anything else is a regression in how
# the rule builds the path, and fails the fetch here.
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

# The project beside this fixture, copied because Pkg writes to the project it is given.
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
