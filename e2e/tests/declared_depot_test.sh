#!/usr/bin/env bash
# julia.depot with `depot = "{HOME}/..."` instantiates into that directory instead of the ambient
# depot. env.sh exports the expanded path with a trailing separator (so Julia's bundled depots stay
# on the path), the stamp names the same depot, and the packages are there.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

env_sh="$(abspath "$1")"
stamp="$(abspath "$2")"
rel="$3"

# {HOME} is expanded at fetch time in the fetching user's environment, which is not the test's
# sandboxed HOME. So the test checks the shape of the exported path (absolute, ending in the
# template's tail and a trailing separator, no placeholder left) and that the stamp and the
# directory agree with it, instead of recomputing the path from its own HOME.
exported="$(
    # shellcheck disable=SC1090
    . "$env_sh"
    printf '%s\n' "${JULIA_DEPOT_PATH:-}"
)"
case "$exported" in
    /*"/$rel:") ;;
    *) fail "env.sh exports JULIA_DEPOT_PATH=$exported, expected an absolute path ending in /$rel: (expanded {HOME}, trailing separator)" ;;
esac
case "$exported" in
    *"{HOME}"*|*"{USER}"*) fail "env.sh still carries a placeholder: $exported" ;;
esac
[ "$(stamp_value "$stamp" depot)" = "$exported" ] ||
    fail "stamp says depot=$(stamp_value "$stamp" depot) but env.sh exports $exported"
depot="${exported%:}"
[ -d "$depot/packages" ] ||
    fail "$depot has no packages/; the fetch did not instantiate into the declared depot"

echo "PASS: declared depot $depot"
