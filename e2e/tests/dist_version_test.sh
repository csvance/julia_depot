#!/usr/bin/env bash
# julia.dist fetched a Julia that RUNS, and it is the version that was asked for.
#
# The sha256 pin already guarantees the bytes. What it does not guarantee is that the
# archive was unpacked with the right strip_prefix, that bin/julia came out executable,
# or that the rest of the distribution came with it: Julia finds its bundled stdlib
# relative to Sys.BINDIR, so a distribution reduced to the binary alone starts and then
# fails on the first `using`. Asking Julia to load a stdlib proves the whole tree.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

julia_bin="$(abspath "$1")"
want="$2"

[ -x "$julia_bin" ] || fail "$julia_bin is not executable"

got="$("$julia_bin" --startup-file=no --version)"
[ "$got" = "julia version $want" ] ||
    fail "expected 'julia version $want', got '$got'"

export JULIA_DEPOT_PATH="$TEST_TMPDIR/depot"
stdlib="$("$julia_bin" --startup-file=no -e 'using TOML; print(isdefined(TOML, :parsefile))')"
[ "$stdlib" = "true" ] ||
    fail "the fetched distribution cannot load its own stdlib: TOML gave '$stdlib'"

echo "PASS: julia.dist produced a working julia $want at $julia_bin"
