#!/usr/bin/env bash
# What a damaged read-only depot does to the environment stacked in front of it. The rule does not
# watch a read-only depot's contents (docs/src/contract.md, "What is not hermetic"), so each case is
# damage done AFTER the fetch, and the question is what loading the environment then does and
# whether a refetch, which is instantiate.sh run again on the same path, repairs it.
#
# Each case damages its own copy of the shared depot read_only_depots_1_12's hook seeded, behind an
# empty `dir`, so nothing the fetch filled is touched. The outcomes, as Julia behaves today:
#
#   package removed            load fails; refetch installs it into `dir`
#   artifact removed           load fails; refetch installs it into `dir`
#   artifact library truncated load fails; refetch does NOT repair it, the directory is present
#   compiled cache corrupted   rejected and recompiled into `dir`; loads correctly
#   package source modified    loads the modified code, silently; refetch does not notice
#   Overrides.toml added       redirects the artifact, silently
#
# The last two are the trust the contract page describes, asserted so the page stays true: if
# Julia starts verifying what it loads, they fail here, and the page should change with them.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

stamp="$(abspath "$1")"
instantiate="$(abspath "$2")"
julia_bin="$(abspath "$3")"
manifest="$(abspath "$4")"

IFS=: read -r -a entries <<<"$(stamp_value "$stamp" depot)"
seeded="${entries[1]}"
[ -d "$seeded/packages/Crayons" ] || fail "$seeded holds no Crayons; the shared depot was not seeded"
# The project's one artifact, Bzip2_jll's.
bz2_hash="$(ls "$seeded/artifacts")"
[ "$(wc -w <<<"$bz2_hash")" -eq 1 ] || fail "expected one artifact in $seeded, found: $bz2_hash"

# A case: a writable copy of the seeded depot as `shared`, an empty `dir` in front of it, and a
# copy of the project. Pkg leaves installed files read-only, hence the chmod before damage.
case_dir=""
new_case() {
    case_dir="$TEST_TMPDIR/$1"
    mkdir -p "$case_dir/dir"
    cp -a "$seeded" "$case_dir/shared"
    chmod -R u+w "$case_dir/shared"
    copy_project "$manifest" "$case_dir/project" >/dev/null
}

# The path the rule exports for this stack: `dir`, the read-only depot, and the trailing separator
# that keeps Julia's bundled depots last.
depot_path() {
    printf '%s\n' "$case_dir/dir:$case_dir/shared:"
}

# Loads both packages and prints what was loaded, from where. Offline: a load never downloads.
load() {
    env JULIA_DEPOT_PATH="$(depot_path)" JULIA_PKG_OFFLINE=true \
        "$julia_bin" --startup-file=no --project="$case_dir/project" -e '
            using Crayons, Bzip2_jll
            println("modified=", isdefined(Crayons, :DAMAGED))
            println("artifact=", Bzip2_jll.artifact_dir)
            ccall((:BZ2_bzlibVersion, Bzip2_jll.libbzip2), Cstring, ())
            println("loaded")' 2>&1
}

# What `bazel fetch --force` runs: instantiate.sh on the same depot path.
refetch() {
    output="$(env JULIA_DEPOT_BIN="$julia_bin" JULIA_DEPOT_PATH="$(depot_path)" \
        "$instantiate" "$case_dir/project" "$case_dir/project/Manifest.toml" "$case_dir/stamp.txt" 2>&1)" ||
        fail "the refetch failed in $case_dir:
$output"
}

expect_load_fails() {
    local what="$1" message="$2"
    if output="$(load)"; then
        fail "$what: the environment loaded, expected it to fail with \"$message\":
$output"
    fi
    grep -qF "$message" <<<"$output" || fail "$what: load failed, but not with \"$message\":
$output"
}

expect_loads() {
    local what="$1"
    output="$(load)" || fail "$what: the environment did not load:
$output"
    grep -qx loaded <<<"$output" || fail "$what: no \"loaded\" in:
$output"
}

# --- package removed: an error naming it, and a refetch installs it into `dir` ---
new_case package_removed
rm -rf "$case_dir/shared/packages/Crayons"
expect_load_fails "package removed" "Package Crayons [a8cc5b0e-0ffa-5ad4-8c14-923d3ee1735f] is required but does not seem to be installed"
refetch
[ -d "$case_dir/dir/packages/Crayons" ] || fail "package removed: the refetch did not install Crayons into dir:
$output"
[ ! -e "$case_dir/shared/packages/Crayons" ] || fail "package removed: the refetch wrote Crayons into the read-only depot"
expect_loads "package removed, after the refetch"

# --- artifact removed: an error naming it, and a refetch installs it into `dir` ---
new_case artifact_removed
rm -rf "$case_dir/shared/artifacts/$bz2_hash"
expect_load_fails "artifact removed" "Artifact \"Bzip2\" was not found"
refetch
[ -d "$case_dir/dir/artifacts/$bz2_hash" ] || fail "artifact removed: the refetch did not install the artifact into dir:
$output"
expect_loads "artifact removed, after the refetch"
grep -qx "artifact=$case_dir/dir/artifacts/$bz2_hash" <<<"$output" ||
    fail "artifact removed: after the refetch the artifact did not load from dir:
$output"

# --- artifact library truncated: an error, and a refetch does not repair it ---
# Pkg takes an artifact directory that exists as installed, so the damage stays in front of the
# fix: only whoever maintains the shared depot can repair it, or `dir` must stop stacking it.
new_case artifact_truncated
lib="$(find "$case_dir/shared/artifacts/$bz2_hash/lib" -name 'libbz2.so.*' -type f | head -n 1)"
[ -n "$lib" ] || fail "no libbz2.so.* file in the artifact to truncate"
: >"$lib"
expect_load_fails "artifact library truncated" "could not load library"
refetch
[ ! -d "$case_dir/dir/artifacts/$bz2_hash" ] || fail "artifact library truncated: the refetch installed the artifact into dir after all, so the docs that say it cannot repair this are wrong:
$output"
expect_load_fails "artifact library truncated, after the refetch" "could not load library"

# --- compiled caches corrupted: rejected and rebuilt into `dir` ---
for ext in ji so; do
    new_case "cache_corrupted_$ext"
    for f in "$case_dir"/shared/compiled/v1.*/Crayons/*."$ext"; do
        [ -f "$f" ] || fail "no .$ext cache for Crayons in the shared depot"
        printf 'damaged' | dd of="$f" bs=1 seek=512 conv=notrunc status=none
    done
    expect_loads "corrupted .$ext cache"
    grep -qx modified=false <<<"$output" || fail "corrupted .$ext cache: loaded modified code:
$output"
    compgen -G "$case_dir/dir/compiled/v1.*/Crayons/*.ji" >/dev/null ||
        fail "corrupted .$ext cache: no cache rebuilt into dir, so the corrupted one was used:
$output"
done

# --- package source modified: loads, silently, and a refetch does not notice ---
new_case source_modified
src="$(echo "$case_dir"/shared/packages/Crayons/*/src/Crayons.jl)"
sed -i 's/^module Crayons$/module Crayons\nconst DAMAGED = true/' "$src"
grep -q 'const DAMAGED' "$src" || fail "could not modify $src"
expect_loads "package source modified"
grep -qx modified=true <<<"$output" || fail "package source modified: the modified code was not loaded, so Julia now checks package sources and docs/src/contract.md should say so:
$output"
refetch
expect_loads "package source modified, after the refetch"
grep -qx modified=true <<<"$output" || fail "package source modified: the refetch repaired it, so docs/src/contract.md should say so:
$output"

# --- Overrides.toml added: the artifact is redirected, silently ---
new_case overrides_added
cp -a "$case_dir/shared/artifacts/$bz2_hash" "$case_dir/elsewhere"
printf '%s = "%s"\n' "$bz2_hash" "$case_dir/elsewhere" >"$case_dir/shared/artifacts/Overrides.toml"
expect_loads "Overrides.toml added"
grep -qx "artifact=$case_dir/elsewhere" <<<"$output" || fail "Overrides.toml added: the artifact was not redirected, so Julia no longer reads overrides from every depot and docs/src/contract.md should say so:
$output"

echo "PASS: damaged read-only depots behave as docs/src/contract.md says"
