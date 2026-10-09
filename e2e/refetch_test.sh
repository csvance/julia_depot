#!/usr/bin/env bash
# Editing a depot's Project.toml, or a file in its project_srcs, reaches the sysimage built from it.
#
# Usage: e2e/refetch_test.sh   (from anywhere; runs Bazel in e2e/)
#
# A julia.depot repository keeps its own copies of the Project.toml and project_srcs it was
# fetched for, and the sysimage rules build from those copies. A copy follows its file only
# because the fetch watches it: an edit must refetch the depot on the next build. Without the
# watch, the sysimage would be built from a stale copy and its inputs file would not change.
#
# That is Bazel refetching a repository between two builds, which a test action cannot do around
# itself, so this script drives Bazel from outside and is not an sh_test. It builds only inputs
# files, never a sysimage. It appends a TOML comment, which changes a file's bytes and not what
# Pkg resolves, and restores the file on any exit.
set -euo pipefail

e2e="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# recorded <target> <key>: the sha256 the target's inputs file records for <key>, after building
# only that file.
recorded() {
    (cd "$e2e" && bazel build --output_groups=inputs "$1" >/dev/null 2>&1) ||
        fail "bazel build --output_groups=inputs $1 failed; rerun it to see why"
    local inputs
    inputs="$(cd "$e2e" && bazel cquery --output=files --output_groups=inputs "$1" 2>/dev/null)"
    sed -n "s|^ *\"$2\": \"\([0-9a-f]*\)\",\{0,1\}\$|\1|p" "$e2e/$inputs"
}

sha() {
    sha256sum "$1" | cut -c1-64
}

# check <file> <target> <key>: edit <file>, expect <target>'s inputs file to record the edit
# under <key>, restore it, and expect the record to return. The file is restored on any exit.
check() {
    local file="$e2e/$1" target="$2" key="$3" backup before edited restored
    backup="$(mktemp)"
    cp "$file" "$backup"
    trap 'cp "'"$backup"'" "'"$file"'"' EXIT

    before="$(recorded "$target" "$key")"
    [ "$before" = "$(sha "$file")" ] ||
        fail "before any edit, $target records $key as '$before', not $(sha "$file")"

    printf '# refetch_test.sh: an edit that changes the bytes and not the environment\n' >> "$file"
    edited="$(recorded "$target" "$key")"
    [ "$edited" = "$(sha "$file")" ] ||
        fail "after editing $1, $target records '$edited' for $key, not the edited file's $(sha "$file"); the depot did not refetch"

    cp "$backup" "$file"
    trap - EXIT
    rm -f "$backup"
    restored="$(recorded "$target" "$key")"
    [ "$restored" = "$before" ] ||
        fail "after restoring $1, $target records '$restored' for $key, not the original $before"
    echo "ok: editing $1 refetched the depot, and restoring it restored the record"
}

# The Project.toml beside a depot's Manifest.
check projects/v1.13/Project.toml //image:sysimage_1_13 project/Project.toml

# A workspace member listed in project_srcs of a depot whose lock is elsewhere: a watched file
# outside the Manifest's directory.
check projects/workspace/packages/WsMember/Project.toml //image:workspace_sysimage project/packages/WsMember/Project.toml

echo "PASS: editing a depot's Project.toml or a project_srcs file refetched it and changed the sysimage's inputs, and restoring it changed them back"
