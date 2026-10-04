#!/usr/bin/env bash
# Two independent builds of a layer are the same bytes.
#
# Usage: image_determinism_test.sh <dist> <dist again> <depot> <depot again> <compiled> <compiled again>
#
# Each pair is two targets with identical attributes, so Bazel ran two separate actions, in
# separate sandboxes and temporary directories, at different times. A layer whose digest moves
# between them would move on every rebuild, and nothing downstream (a registry, a cache, a
# reviewer comparing digests) could tell a real change from noise.
#
# The compiled layer is the exception the docs admit to. Julia stamps every cache with a build id,
# so its bytes differ, and names each cache file with a hash over the paths of the build (the
# project, the Julia binary), which live in a fresh temporary tree each time. Its STRUCTURE must
# not differ: the same caches for the same packages, with the same modes, owners and mtimes.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../tests/common.sh"

same_bytes() {
    local a b
    a="$(sha256sum < "$(abspath "$1")" | cut -d' ' -f1)"
    b="$(sha256sum < "$(abspath "$2")" | cut -d' ' -f1)"
    [ "$a" = "$b" ] || fail "$(basename "$1") and $(basename "$2") differ: $a vs $b
$(diff <(tar -tvf "$1" --numeric-owner --full-time) <(tar -tvf "$2" --numeric-owner --full-time) | head -20)"
    echo "same: $(basename "$1") $a"
}

same_bytes "$1" "$2"
same_bytes "$3" "$4"

# Names up to the path hash, modes, owners and mtimes; not sizes, which the build id can change.
shape() {
    tar --list --verbose --numeric-owner --full-time --file "$(abspath "$1")" |
        awk '{ $3 = ""; print }' | sed -E 's/_[A-Za-z0-9]{5}\.(ji|so)$/_<hash>.\1/'
}
[ "$(shape "$5")" = "$(shape "$6")" ] || fail "the compiled layers have different entries:
$(diff <(shape "$5") <(shape "$6") | head -20)"
if cmp -s "$5" "$6"; then
    echo "same: $(basename "$5"), bytes included"
else
    echo "same entries: $(basename "$5"), bytes differ (cache build ids)"
fi

echo "PASS: the dist and depot layers are reproducible, the compiled layer's structure is"
