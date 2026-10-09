#!/usr/bin/env bash
# The actions behind julia/image.bzl: one subcommand per layer rule, plus the precompile check.
# Internal: its subcommands and arguments are not part of the module's interface.
#
#   image_layers.sh dist      <julia> <prefix> <out.tar>
#   image_layers.sh depot     <julia> <out.tar> <source stamp|-> [<rel> <file>]...
#   image_layers.sh sysimage  <julia> <out.tar> <source stamp> <path in image> <sysimage args>...
#   image_layers.sh sysimage_so <julia> <out.so> <source stamp> <sysimage args>...
#   image_layers.sh compiled  <julia> <out.tar> <image flags>...
#   image_layers.sh check     <julia> <image flags>... [--modules "A B"]
#
# <julia> is the toolchain's bin/julia. <rel> <file> pairs stage a project: each file is copied to
# <rel> under a fresh directory, which becomes the project Pkg sees. <sysimage args> are any number
# of `--env <KEY=VALUE>`, a variable for the build with {execroot} expanded to the absolute
# execution root, followed by the <rel> <file> pairs. <image flags> describe the image
# the caches are for, and are written by image.bzl from a julia_image_env:
#
#   --layer <tar>          a layer, unpacked in the order given (repeatable)
#   --julia-prefix <dir>   where the image keeps Julia, e.g. /opt/julia
#   --depot <dir>          one JULIA_DEPOT_PATH entry, in search order (repeatable)
#   --project <dir>        an entry project, as the image names it (repeatable)
#   --sysimage <path>      the sysimage the image starts Julia with, if not Julia's own
#   --env <KEY=VALUE>      a variable for Julia, with {root} expanded to the unpacked tree (repeatable)
#
# A script keeps the rules small and the logic beside the scripts it wraps: `depot` is
# image_depot.sh and `sysimage` is sysimage.sh, each staged and tarred. What they decide is
# documented there.
#
# write_layer below writes every layer as a deterministic tar: entries sorted by name, mtimes
# zeroed, owned by uid and gid 0 by number, permissions normalised to 0755 for directories and
# executables and 0644 for everything else, GNU format. The stage's children are passed in sorted
# order, because tar sorts what it reads from a directory but not its arguments. The same inputs
# give the same bytes, so a layer's digest changes only when its content does.
set -euo pipefail

cmd="${1:?usage: image_layers.sh dist|depot|sysimage|sysimage_so|compiled|check ...}"
shift

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Bazel starts every action in the execution root; {execroot} in a sysimage's env expands to it.
execroot="$PWD"

# Julia and PackageCompiler both call homedir(), which throws when HOME is unset, and a Bazel action
# is not given one. A private HOME also keeps a build from writing into the developer's.
scratch="$(mktemp -d)"
# Pkg leaves installed packages read-only, which rm -rf alone cannot delete.
trap 'chmod -R u+w "$scratch" 2>/dev/null; rm -rf "$scratch"' EXIT
export HOME="$scratch/home"
mkdir -p "$HOME"

abspath() {
    printf '%s/%s\n' "$(cd "$(dirname "$1")" && pwd)" "$(basename "$1")"
}

# write_layer <out.tar> <stage dir>: the stage's children, as one deterministic layer.
write_layer() {
    local out="$1" stage="$2"
    local -a members
    mapfile -t members < <(cd "$stage" && LC_ALL=C ls -A | LC_ALL=C sort)
    [ "${#members[@]}" -gt 0 ] || {
        echo "FAILED: nothing to put in $out" >&2
        exit 1
    }
    LC_ALL=C tar --create --file "$out" \
        --format=gnu \
        --sort=name \
        --mtime=@0 \
        --owner=0 --group=0 --numeric-owner \
        --mode='u=rwX,go=rX' \
        --directory "$stage" \
        "${members[@]}"
}

# The distribution's own directory, through any symlinks Bazel staged in front of it.
julia_root() {
    cd "$(dirname "$(readlink -f "$1")")/.." && pwd
}

# The full depot path a julia_depot stamp.txt records, the one the fetch ran with, since a package
# or artifact the fetch found already present may be in any entry. The trailing separator is
# stripped, because it would add the bundled depots of whichever Julia reads the path; callers that
# want them append them by name.
stamp_depot() {
    local d
    d="$(sed -n 's/^depot=//p' "$1")"
    [ -n "$d" ] || {
        echo "FAILED: $1 records no depot=" >&2
        exit 1
    }
    d="${d%:}"
    printf '%s\n' "${d#:}"
}

# stage_project <dir> [<rel> <file>]...: copies each file to <dir>/<rel>. cp -L, because Bazel
# stages inputs as symlinks and Pkg resolves a project by its real path, so a symlinked
# Project.toml would find the Manifest.toml beside the original, not the one staged here.
stage_project() {
    local dir="$1"
    shift
    mkdir -p "$dir"
    while [ "$#" -gt 0 ]; do
        mkdir -p "$dir/$(dirname "$1")"
        cp -L "$2" "$dir/$1"
        chmod u+w "$dir/$1"
        shift 2
    done
}

# --- the image flags, shared by compiled and check -----------------------------------------
layers=()
depots=()
projects=()
julia_prefix=""
sysimage=""
modules=""
envs=()

parse_image_flags() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --layer) layers+=("$2") ;;
            --depot) depots+=("$2") ;;
            --project) projects+=("$2") ;;
            --julia-prefix) julia_prefix="$2" ;;
            --sysimage) sysimage="$2" ;;
            --modules) modules="$2" ;;
            --env) envs+=("$2") ;;
            *)
                echo "unknown flag $1" >&2
                exit 2
                ;;
        esac
        shift 2
    done
    [ -n "$julia_prefix" ] || {
        echo "--julia-prefix is required" >&2
        exit 2
    }
    [ "${#depots[@]}" -gt 0 ] || {
        echo "at least one --depot is required" >&2
        exit 2
    }
    [ "${#projects[@]}" -gt 0 ] || {
        echo "at least one --project is required" >&2
        exit 2
    }
}

# unpack_image <root> <toolchain julia>: unpacks the layers into <root> in order, as an overlay
# filesystem would stack them. Then sets, for that tree:
#
#   image_julia       the image's own Julia when a dist layer put one there, else the toolchain's
#   image_depot_path  the image's JULIA_DEPOT_PATH with <root> in front of every entry
#
# A depot under the Julia prefix (the distribution's bundled depots) is taken from the toolchain
# when no dist layer supplied Julia, since the toolchain is the same distribution.
#
# This is what lets caches built here load in the image. Julia records a cached package's sources
# relative to the depot that holds them ("@depot/packages/...") and checks them by content, so a
# cache compiled against <root>/opt/julia-depot is valid at /opt/julia-depot as long as the depot
# path has the same shape. Sources outside every depot are recorded by absolute path, so an
# application's own packages need their directory listed as a depot too.
unpack_image() {
    local root="$1" toolchain="$2" layer d
    mkdir -p "$root"
    for layer in "${layers[@]}"; do
        tar --extract --file "$layer" --directory "$root" --no-same-owner
    done
    local fallback
    fallback="$(julia_root "$toolchain")"
    if [ -x "$root$julia_prefix/bin/julia" ]; then
        image_julia="$root$julia_prefix/bin/julia"
        fallback="$root$julia_prefix"
        echo "==> running the image's own Julia, $julia_prefix/bin/julia from the layers"
    else
        image_julia="$(abspath "$toolchain")"
        echo "==> no Julia at $julia_prefix/bin/julia in the layers; running the toolchain's"
    fi
    image_depot_path=""
    for d in "${depots[@]}"; do
        case "$d" in
            "$julia_prefix"/*) d="$fallback${d#"$julia_prefix"}" ;;
            *) d="$root$d" ;;
        esac
        image_depot_path="${image_depot_path:+$image_depot_path:}$d"
    done
    # The rule's variables are set only now that <root> exists, because a value may name a file in
    # a layer the image does not ship, such as a driver stub that lets a package load on a build
    # host with no driver.
    local e v
    for e in ${envs[@]+"${envs[@]}"}; do
        v="${e#*=}"
        # The replacement is quoted so bash 5.2 does not read an & in the path as the match.
        export "${e%%=*}=${v//\{root\}/"$root"}"
    done
    image_julia_args=(--startup-file=no)
    if [ -n "$sysimage" ]; then
        [ -f "$root$sysimage" ] || {
            echo "FAILED: the sysimage $sysimage is in none of the layers" >&2
            exit 1
        }
        image_julia_args+=("--sysimage=$root$sysimage")
    fi
}

# --- dist: the distribution at a prefix ----------------------------------------------------
# Copied from the distribution's real directory, because Bazel's staging dereferences symlinks and
# the distribution's own relative links (libjulia.so -> libjulia.so.1.12.7 and about eighty more)
# would each become a second copy of the library. The files are the ones the rule declares as
# inputs; copying this way also keeps the links. An absolute link would dangle in an image, so it
# fails the build.
cmd_dist() {
    local julia="$1" prefix="${2#/}" out="$3"
    local src stage
    src="$(julia_root "$julia")"
    stage="$scratch/stage"
    mkdir -p "$stage/$(dirname "$prefix")"
    cp -a "$src" "$stage/$prefix"
    chmod -R u+w "$stage/$prefix"
    # Drop the files Bazel added to the repository.
    rm -f "$stage/$prefix/BUILD.bazel" "$stage/$prefix/WORKSPACE" "$stage/$prefix/REPO.bazel"
    local bad
    bad="$(find "$stage/$prefix" -type l -lname '/*' | head -5)"
    [ -z "$bad" ] || {
        echo "FAILED: the distribution has absolute symlinks, which would dangle in an image:" >&2
        printf '%s\n' "$bad" >&2
        exit 1
    }
    [ -x "$stage/$prefix/bin/julia" ] || {
        echo "FAILED: no bin/julia under $src" >&2
        exit 1
    }
    write_layer "$out" "$stage"
}

# --- depot: image_depot.sh on a staged project ---------------------------------------------
# image_depot.sh reads its options (JULIA_DEPOT_CONTENTS and the rest) from the environment, which
# the rule sets. This supplies what it needs from the build: Julia, the staged project, and a
# source depot for registries and server credentials. With no stamp the source depot is empty, so
# the registry is fetched into the clean depot instead of copied from this host. The manifest pins
# every package by tree hash, so the registry's state cannot change what is installed.
cmd_depot() {
    local julia="$1" out="$2" stamp="$3"
    shift 3
    local project="$scratch/project"
    stage_project "$project" "$@"
    if [ "$stamp" = "-" ]; then
        mkdir -p "$scratch/source-depot"
        export JULIA_DEPOT_PATH="$scratch/source-depot"
    else
        JULIA_DEPOT_PATH="$(stamp_depot "$stamp")"
        export JULIA_DEPOT_PATH
    fi
    JULIA_DEPOT_BIN="$(abspath "$julia")" "$here/image_depot.sh" "$project" "$(abspath "$out")"
}

# --- sysimage: sysimage.sh on a staged project, at a path in the image ---------------------
# The project's packages come from the depot path the stamp names, which julia.depot has already
# instantiated. That path is only read. A scratch depot in front takes anything PackageCompiler
# writes (its own environment, when the depot lacks it, and the build's caches), and the
# distribution's bundled depots behind supply the stdlib.
#
# build_sysimage <julia> <out.so> <stamp> <sysimage args>...: the build both subcommands share.
build_sysimage() {
    local julia="$1" out="$2" stamp="$3" e v
    shift 3
    while [ "${1:-}" = "--env" ]; do
        e="$2" v="${2#*=}"
        # The replacement is quoted so bash 5.2 does not read an & in the path as the match.
        export "${e%%=*}=${v//\{execroot\}/"$execroot"}"
        shift 2
    done
    local project="$scratch/project" root
    stage_project "$project" "$@"
    root="$(julia_root "$julia")"
    mkdir -p "$scratch/depot" "$(dirname "$out")"
    JULIA_DEPOT_PATH="$scratch/depot:$(stamp_depot "$stamp"):$root/local/share/julia:$root/share/julia" \
        JULIA_DEPOT_BIN="$(abspath "$julia")" \
        "$here/sysimage.sh" "$project" auto "$out"
}

cmd_sysimage() {
    local julia="$1" out="$2" stamp="$3" path="${4#/}"
    shift 4
    local stage="$scratch/stage"
    build_sysimage "$julia" "$stage/$path" "$stamp" "$@"
    write_layer "$out" "$stage"
}

# --- sysimage_so: the same sysimage as a file, for a build that starts Julia with it directly ---
cmd_sysimage_so() {
    local julia="$1" out="$2" stamp="$3"
    shift 3
    build_sysimage "$julia" "$(abspath "$out")" "$stamp" "$@"
}

# --- compiled: the precompile caches for the entry projects --------------------------------
# The layers are unpacked into one tree with the image's layout and every entry project is
# precompiled in it, with the image's depot path rooted in that tree. Only <first depot>/compiled
# goes into the layer: Julia writes caches there, and the rest of the tree is other layers' content.
#
# Each project is precompiled separately because a cache depends on the active project's
# preferences (a LocalPreferences.toml can change what a package compiles to), so each entry point
# needs the caches its own environment selects. JULIA_CPU_TARGET comes from the rule and makes
# every cache multi-versioned for that target list, so it loads on any CPU the list covers.
# Offline, since every package is already in the tree. Strict, so a package that fails to
# precompile fails the build instead of a container at its first start. already_instantiated,
# because otherwise Pkg.precompile runs instantiate first, which finds no registry in the tree and
# downloads General into it despite JULIA_PKG_OFFLINE: a network fetch in an action that declares
# none.
cmd_compiled() {
    local julia="$1" out="$2"
    shift 2
    parse_image_flags "$@"
    : "${JULIA_CPU_TARGET:?the compiled layer needs JULIA_CPU_TARGET; image.bzl sets it}"
    local root="$scratch/root" p
    unpack_image "$root" "$julia"
    for p in "${projects[@]}"; do
        echo "==> precompiling $p for $JULIA_CPU_TARGET"
        JULIA_DEPOT_PATH="$image_depot_path" JULIA_PKG_OFFLINE=true \
            "$image_julia" "${image_julia_args[@]}" --project="$root$p" \
            -e 'using Pkg; Pkg.precompile(; strict = true, already_instantiated = true)'
    done
    local compiled="${depots[0]#/}/compiled"
    [ -d "$root/$compiled" ] || {
        echo "FAILED: precompiling wrote nothing to /$compiled" >&2
        exit 1
    }
    local stage="$scratch/stage"
    mkdir -p "$stage/$(dirname "$compiled")"
    mv "$root/$compiled" "$stage/$compiled"
    write_layer "$out" "$stage"
}

# --- check: the image starts without precompiling ------------------------------------------
# Unpacks the layers as cmd_compiled does and, in each entry project, loads its modules with
# loading debug output on. Julia logs every cache it rejects and every package it compiles; a clean
# run logs neither. The modules are the project's direct dependencies, plus the project itself when
# it is a package, unless --modules names them.
#
# One rejection is benign and filtered out: Julia's bundled stdlib caches include a variant built
# with other compiler flags beside the one that loads, and skipping it is logged "since the flags
# are mismatched". Any other rejection means a cache was stale, and any compile means one was
# missing.
cmd_check() {
    local julia="$1"
    shift
    parse_image_flags "$@"
    local root="${TEST_TMPDIR:-$scratch}/image-root" p log bad fail=0
    unpack_image "$root" "$julia"
    for p in "${projects[@]}"; do
        log="$(
            # shellcheck disable=SC2086
            JULIA_DEPOT_PATH="$image_depot_path" JULIA_DEBUG=loading JULIA_PKG_OFFLINE=true \
                "$image_julia" "${image_julia_args[@]}" --project="$root$p" -e '
                    using TOML
                    file = Base.active_project()
                    project = TOML.parsefile(file)
                    mods = isempty(ARGS) ? sort!(collect(keys(get(project, "deps", Dict())))) : ARGS
                    if isempty(ARGS) && haskey(project, "name") &&
                            isfile(joinpath(dirname(file), "src", project["name"] * ".jl"))
                        pushfirst!(mods, project["name"])
                    end
                    isempty(mods) && error("$file has no dependencies to load; pass modules")
                    for m in mods
                        t = @elapsed Base.require(Main, Symbol(m))
                        println("loaded ", m, " in ", round(t; digits = 2), " s")
                    end
                ' $modules 2>&1
        )" || {
            echo "FAILED: $p: loading failed:"
            printf '%s\n' "$log" | tail -30
            fail=1
            continue
        }
        bad="$(printf '%s\n' "$log" | grep -E 'Rejecting cache file|Precompiling|Being precompiled' |
            grep -v 'since the flags are mismatched' || true)"
        if [ -n "$bad" ]; then
            echo "FAILED: $p: loading compiled or rejected caches:"
            printf '%s\n' "$bad" | sed 's/^/    /' | cut -c1-240 | head -20
            fail=1
        else
            echo "ok: $p: $(printf '%s\n' "$log" | grep '^loaded ' | tr '\n' ' ')"
        fi
    done
    [ "$fail" -eq 0 ] || exit 1
    echo "PASS: every entry project loads without precompiling or rejecting a cache"
}

case "$cmd" in
    dist) cmd_dist "$@" ;;
    depot) cmd_depot "$@" ;;
    sysimage) cmd_sysimage "$@" ;;
    sysimage_so) cmd_sysimage_so "$@" ;;
    compiled) cmd_compiled "$@" ;;
    check) cmd_check "$@" ;;
    *)
        echo "unknown subcommand $cmd" >&2
        exit 2
        ;;
esac
