#!/usr/bin/env bash
# The layers hold what each one promises, and every entry in them is normalised.
#
# Usage: image_layers_test.sh <dist.tar> <depot.tar> <compiled.tar> <image env> <minor>
#
# Normalised means: owned by 0:0 by number, mtime the epoch, and one of four modes (0755 for
# directories and executables, 0644 for other files, and symlinks, which have no mode of their
# own). A layer that leaks the builder's uid, a build-time mtime or a umask is a layer whose digest
# depends on who built it and when, and a read-only file from Pkg would stay read-only in the image.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../tests/common.sh"

dist="$(abspath "$1")"
depot="$(abspath "$2")"
compiled="$(abspath "$3")"
image_env="$(abspath "$4")"
minor="$5"

# Listed once into a file, then searched: `tar | grep -q` under pipefail fails whenever grep
# finds its match early and tar dies of the closed pipe.
listing() {
    local f="$TEST_TMPDIR/$(basename "$1").verbose"
    [ -f "$f" ] || tar --list --verbose --numeric-owner --full-time --file "$1" > "$f"
    cat "$f"
}

names() {
    local f="$TEST_TMPDIR/$(basename "$1").names"
    [ -f "$f" ] || tar --list --file "$1" > "$f"
    cat "$f"
}

assert_normalised() {
    local tar="$1" bad
    bad="$(listing "$tar" | awk '
        $1 !~ /^(drwxr-xr-x|-rwxr-xr-x|-rw-r--r--|lrwxr-xr-x|hrw-r--r--|hrwxr-xr-x)$/ ||
        $2 != "0/0" || $4 != "1970-01-01" || $5 != "00:00:00" { print }' | head -5)"
    [ -z "$bad" ] || fail "$(basename "$tar") has entries that are not normalised:
$bad"
}

has() {
    local tar="$1" pattern="$2" what="$3"
    grep -qE -- "$pattern" <(names "$tar") || fail "$(basename "$tar") has no $what ($pattern)"
}

for t in "$dist" "$depot" "$compiled"; do
    assert_normalised "$t"
done

# --- the distribution -----------------------------------------------------------------------
grep -qE '^-rwxr-xr-x .* opt/julia/bin/julia$' <(listing "$dist") ||
    fail "the dist layer has no executable opt/julia/bin/julia"
# The distribution's own relative links survive, rather than each becoming a second copy.
grep -qE '^lrwxr-xr-x .* opt/julia/lib/libjulia\.so -> libjulia\.so\.' <(listing "$dist") ||
    fail "the dist layer lost the libjulia.so symlink"
if grep -qE '^opt/julia/(BUILD\.bazel|REPO\.bazel|WORKSPACE)$' <(names "$dist"); then
    fail "the dist layer ships the repository's Bazel files"
fi
has "$dist" '^opt/$' "opt/ entry of its own"

# --- the depot ------------------------------------------------------------------------------
has "$depot" '^opt/julia-depot/packages/Crayons/' "Crayons package"
has "$depot" '^opt/julia-depot/artifacts/[0-9a-f]{40}/.*libbz2' "libbz2 artifact"
if grep -qE '^opt/julia-depot/(registries|servers|compiled)/' <(names "$depot"); then
    fail "the depot layer carries registries, servers or caches"
fi

# --- the caches -----------------------------------------------------------------------------
others="$(names "$compiled" | grep -vE '^(opt/|opt/julia-depot/|opt/julia-depot/compiled/.*)$' || true)"
[ -z "$others" ] || fail "the compiled layer holds more than the depot's compiled/:
$others"
has "$compiled" "^opt/julia-depot/compiled/v$minor/Crayons/.*\.ji$" "Crayons cache"
has "$compiled" "^opt/julia-depot/compiled/v$minor/Bzip2_jll/.*\.so$" "Bzip2_jll package image"

# --- the environment ------------------------------------------------------------------------
want="JULIA_CPU_TARGET=generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1);x86-64-v4,-rdrnd,base(1)
JULIA_DEPOT_PATH=/opt/julia-depot:/opt/julia/local/share/julia:/opt/julia/share/julia
JULIA_PKG_OFFLINE=true
JULIA_PROJECT=/opt/app
PATH=/opt/julia/bin:\$PATH"
[ "$(cat "$image_env")" = "$want" ] || fail "the image environment is not what the layout declares:
$(cat "$image_env")
expected:
$want"

echo "PASS: dist, depot and compiled layers are normalised and hold what they should; the environment matches"
