#!/usr/bin/env bash
# julia.depot with `read_only_depots` stacks them after `dir`: env.sh exports
# <dir>:<shared>:<absent>: in that order with the trailing separator, the stamp records the
# same path, the missing depot neither failed the fetch nor was created, what the shared depot
# already held (hooks/seed_shared_depot.sh seeds it before instantiate) was not installed into
# `dir` again, and the fetch wrote nothing into the shared depot.
#
# Then image_depot.sh on the stamp's path. The registry lives only in the shared depot, so a
# script that took its registries from the first entry alone would hand the clean depot none,
# and Pkg would install the default registry from the network instead: the output says which.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# Every entry by path, type and size, then every file's content hash, without timestamps: Julia
# touches a cache file it loads, in whichever depot holds it, to try it first next time (and
# ignores the failure where it may not), so an mtime changes on a plain read.
list_depot() {
    (cd "$1" && find . -printf '%P\t%y\t%s\n' | LC_ALL=C sort &&
        find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum)
}

env_sh="$(abspath "$1")"
stamp="$(abspath "$2")"
rel_dir="$3"
rel_shared="$4"
rel_absent="$5"
image_depot="$(abspath "$6")"
julia_bin="$(abspath "$7")"
manifest="$(abspath "$8")"

# {HOME} expanded at FETCH time, in the fetching user's environment, not the test's sandboxed
# HOME; see declared_depot_test.sh. So the shape is checked, and the entries taken from it.
exported="$(
    # shellcheck disable=SC1090
    . "$env_sh"
    printf '%s\n' "${JULIA_DEPOT_PATH:-}"
)"
case "$exported" in
    /*"/$rel_dir:/"*"/$rel_shared:/"*"/$rel_absent:") ;;
    *) fail "env.sh exports JULIA_DEPOT_PATH=$exported, expected <dir>:<shared>:<absent>: ending in /$rel_dir, /$rel_shared and /$rel_absent with a trailing separator" ;;
esac
IFS=: read -r -a entries <<<"$exported"
[ "${#entries[@]}" -eq 3 ] || fail "env.sh exports ${#entries[@]} depots, expected 3: $exported"
dir="${entries[0]}" shared="${entries[1]}" absent="${entries[2]}"
[ "$(stamp_value "$stamp" depot)" = "$exported" ] ||
    fail "stamp says depot=$(stamp_value "$stamp" depot) but env.sh exports $exported"

# A missing read-only depot is skipped, not created: the rule never writes to one.
[ ! -e "$absent" ] || fail "$absent exists; the fetch must not create a read-only depot"

# Everything the manifest needs is in the shared depot, so `dir` gets none of it: no package,
# no artifact and no registry. The fetch did run there (the stamp exists, and Pkg logs its
# manifest usage to the first depot), so `dir` existing but empty of these is the result.
[ -d "$shared/packages/Crayons" ] || fail "the hook did not seed $shared; nothing here is being tested"
[ -d "$dir" ] || fail "$dir does not exist; the fetch did not run against the declared depot"
for d in packages artifacts registries; do
    if [ -d "$dir/$d" ] && [ -n "$(ls -A "$dir/$d")" ]; then
        fail "$dir/$d is not empty, so the fetch installed what the read-only depot already held:
$(ls -A "$dir/$d")"
    fi
done

# Nothing written into the shared depot after the hook listed it: no new, removed, resized or
# rewritten entry. The hook's list_depot is this one; keep them the same.
listing="$dir/julia_depot_e2e/shared_listing.txt"
[ -f "$listing" ] || fail "no $listing; the hook did not run"
now="$(list_depot "$shared")"
if [ "$now" != "$(cat "$listing")" ]; then
    fail "the fetch wrote into the read-only depot $shared:
$(diff <(cat "$listing") <(printf '%s\n' "$now") || true)"
fi

# image_depot.sh on the stamp's depot path, as julia_depot_layer runs it: the registry is
# copied from the shared depot, so Pkg has no reason to install one.
project="$(copy_project "$manifest" "$TEST_TMPDIR/project")"
output="$(env JULIA_DEPOT_BIN="$julia_bin" JULIA_DEPOT_PATH="$exported" \
    "$image_depot" "$project" "$TEST_TMPDIR/depot.tar" 2>&1)" ||
    fail "image_depot.sh failed on the stacked depot path:
$output"
case "$output" in
    *"Installing known registries"*) fail "image_depot.sh did not copy the read-only depot's registry, so Pkg installed one:
$output" ;;
esac
grep -qE '^opt/julia-depot/artifacts/[0-9a-f]{40}/.*libbz2' <<<"$(tar -tf "$TEST_TMPDIR/depot.tar")" ||
    fail "the depot layer from the stacked depot path has no libbz2"

echo "PASS: read-only depots $exported"
