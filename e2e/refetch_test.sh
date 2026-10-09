#!/usr/bin/env bash
# Editing the Project.toml beside a depot's Manifest reaches the sysimage built from that depot.
#
# Usage: e2e/refetch_test.sh   (from anywhere; runs Bazel in e2e/)
#
# A julia.depot repository keeps its own copy of the Project.toml it was fetched for, and the
# sysimage rules build from that copy. The copy follows the file only because the fetch watches
# it: an edit must refetch the depot on the next build. Without the watch, the sysimage would be
# built from a stale copy and its inputs file would not change.
#
# That is Bazel refetching a repository between two builds, which a test action cannot do around
# itself, so this script drives Bazel from outside and is not an sh_test. It builds only the
# inputs file of //image:sysimage_1_13, never the sysimage. It appends a TOML comment, which
# changes the file's bytes and not what Pkg resolves, and restores the file on any exit.
set -euo pipefail

e2e="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project="$e2e/projects/v1.13/Project.toml"
target=//image:sysimage_1_13

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

backup="$(mktemp)"
cp "$project" "$backup"
trap 'cp "$backup" "$project"; rm -f "$backup"' EXIT

# The inputs file's entry for the project's Project.toml, after building only that file.
recorded() {
    (cd "$e2e" && bazel build --output_groups=inputs "$target" >/dev/null 2>&1) ||
        fail "bazel build --output_groups=inputs $target failed; rerun it to see why"
    local inputs
    inputs="$(cd "$e2e" && bazel cquery --output=files --output_groups=inputs "$target" 2>/dev/null)"
    sed -n 's/^ *"project\/Project.toml": "\([0-9a-f]*\)",\{0,1\}$/\1/p' "$e2e/$inputs"
}

sha() {
    sha256sum "$1" | cut -c1-64
}

before="$(recorded)"
[ "$before" = "$(sha "$project")" ] ||
    fail "before any edit, the inputs file records Project.toml as '$before', not $(sha "$project")"

printf '# refetch_test.sh: an edit that changes the bytes and not the environment\n' >> "$project"
edited="$(recorded)"
[ "$edited" = "$(sha "$project")" ] ||
    fail "after editing Project.toml the inputs file records '$edited', not the edited file's $(sha "$project"); the depot did not refetch"

cp "$backup" "$project"
restored="$(recorded)"
[ "$restored" = "$before" ] ||
    fail "after restoring Project.toml the inputs file records '$restored', not the original $before"

echo "PASS: editing Project.toml refetched the depot and changed the sysimage's inputs, and restoring it changed them back"
