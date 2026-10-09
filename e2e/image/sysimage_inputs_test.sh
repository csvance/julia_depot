#!/usr/bin/env bash
# A sysimage's inputs file identifies what it was built from, the same way on every build.
#
# Usage: sysimage_inputs_test.sh <layer.tar> <layer's sysimage inputs.json> <base inputs.json>
#            <twin inputs.json> <cc variant inputs.json> <env variant inputs.json>
#            <project Manifest.toml> <julia_dist.txt>
#
# The base is a sysimage with every default. The twin is another target with the same
# attributes, so its file must be byte-identical: no target name, time or host path may reach
# it. Each variant changes one attribute, and its file must differ in exactly the entry that
# attribute decides. None of these sysimages is built; only their inputs files are. The layer is
# the image example's, which must ship its own sysimage's inputs file unchanged.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../tests/common.sh"

layer="$(abspath "$1")"
layer_inputs="$(abspath "$2")"
inputs="$(abspath "$3")"
twin="$(abspath "$4")"
cc_variant="$(abspath "$5")"
env_variant="$(abspath "$6")"
manifest="$(abspath "$7")"
dist="$(abspath "$8")"

cmp -s "$inputs" "$twin" ||
    fail "two targets with the same inputs wrote different inputs files:
$(diff "$inputs" "$twin")"

# Only the lines that differ, without diff's own markup.
changed() {
    diff "$1" "$2" | grep '^[<>]' | sed 's/^[<>] *//' | sed 's/": .*//; s/^"//; s/^{"cc":.*/config/' | sort -u
}
[ "$(changed "$inputs" "$cc_variant")" = "cc/bin/cc" ] ||
    fail "changing only the compiler changed other entries than cc/bin/cc:
$(diff "$inputs" "$cc_variant")"
[ "$(changed "$inputs" "$env_variant")" = "config" ] ||
    fail "changing only env changed other entries than config:
$(diff "$inputs" "$env_variant")"
grep -q '"E2E_VALUE":"changed"' "$env_variant" ||
    fail "the env variant's inputs file does not record its env:
$(head -3 "$env_variant")"

want="$(sha256sum "$manifest" | cut -c1-64)"
grep -q "\"project/Manifest.toml\": \"$want\"" "$inputs" ||
    fail "the inputs file does not record the project Manifest's sha256 $want:
$(cat "$inputs")"
sha="$(sed -n 's/^sha256=//p' "$dist")"
version="$(sed -n 's/^version=//p' "$dist")"
grep -qF "\"sha256\": \"$sha\", \"version\": \"$version\"" "$inputs" ||
    fail "the inputs file does not record Julia $version as the tarball $sha:
$(tail -2 "$inputs")"

tar --extract --file "$layer" --directory "$TEST_TMPDIR" opt/julia-sysimage/sys.inputs.json ||
    fail "$(basename "$layer") ships no opt/julia-sysimage/sys.inputs.json beside the sysimage"
cmp -s "$TEST_TMPDIR/opt/julia-sysimage/sys.inputs.json" "$layer_inputs" ||
    fail "the layer's inputs file differs from the rule's inputs output group"

echo "PASS: the inputs file is the same for a twin target, changes only where an input changed, records the Manifest and the Julia tarball, and ships beside the sysimage"
