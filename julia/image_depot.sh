#!/usr/bin/env bash
# Build the depot layer for a container image from a Manifest-pinned project.
#
# Run by julia_depot_layer. Internal: its arguments and variables are not part of the module's
# interface and may change in any release.
#
# Usage: image_depot.sh <project dir> <output tar>
#
# Environment:
#   JULIA_DEPOT_BIN               required, the julia to instantiate with
#   JULIA_DEPOT_PATH              required, the source depot path: the registries/ of its
#                                 entries and the servers/ (package-server credentials) of
#                                 its first are copied into the clean depot so instantiate
#                                 resolves the way the developer does
#   JULIA_PKG_SERVER              optional, passed through to Pkg (default: Pkg's default)
#   JULIA_DEPOT_CONTENTS          artifacts (default) | full, see below
#   JULIA_DEPOT_IMAGE_PREFIX      path of the depot inside the image, default opt/julia-depot
#   JULIA_DEPOT_MIN_ARTIFACTS     sanity floor on artifact directories, default 1
#   JULIA_DEPOT_OVERRIDES_BUILD   optional artifacts/Overrides.toml for the build (see below)
#   JULIA_DEPOT_OVERRIDES_IMAGE   the artifacts/Overrides.toml to ship in the image,
#                                 required whenever the build one is set
#
# JULIA_DEPOT_PATH is Julia's own; the others are this script's.
#
# Why a second depot: depot.bzl conforms the developer's existing depot to the Manifest,
# which suits a workstation build but not an image. That depot holds every project on the
# machine, and this one needs a small part of it. The image gets its own depot, instantiated
# from the Manifest into an empty directory.
#
# Why Pkg selects the artifacts: a static walk of every Artifacts.toml with HostPlatform()
# misses packages that augment the platform with their own code (HDF5_jll ships
# .pkg/platform_augmentation.jl and tags its entries with `mpi`). A plain HostPlatform()
# matches none of those entries and drops the artifact without an error, and the image fails
# with a missing native library at first use. Pkg.instantiate performs the augmented
# selection, so the set is complete and minimal. artifact_paths.jl measures the set; it does
# not choose it.
#
# Why a sysimage does not replace this: a sysimage carries compiled code, not native
# libraries. JLLWrappers resolves artifact directories in __init__ at startup, which is also
# why the artifacts can be at a different path in the image than at build time. With an
# empty depot, startup fails in the first JLL's __init__.
#
# No precompilation in either mode. A cache built against this temporary depot, without the
# image's layout around it, cannot be trusted by the image. A full-mode image either
# precompiles once at first start, or ships the caches of julia_compiled_layer (image.bzl),
# which precompiles in a tree laid out like the image.
#
# Artifact overrides substitute a locally built artifact for a registry one. There are two
# files because the path differs between build and image:
#   - The build-time file names a directory on this host. Pkg.instantiate reads it and skips
#     downloading any artifact whose hash is overridden to an existing directory. Only
#     hash-keyed overrides do this; UUID and name overrides apply at load time.
#   - The image file names the in-image path and is what ships, so it is required whenever
#     the build one is set.
# The build fails if an overridden hash was downloaded anyway, since the image would then
# carry both and load the registry one. Hash keys are read bare or quoted.
set -euo pipefail

proj="${1:?usage: image_depot.sh <project dir> <output tar>}"
out="${2:?usage: image_depot.sh <project dir> <output tar>}"

: "${JULIA_DEPOT_BIN:?JULIA_DEPOT_BIN must be set to the pinned julia}"
: "${JULIA_DEPOT_PATH:?JULIA_DEPOT_PATH must be set; source the depot rule env.sh first}"

# The two override files go together. A build-time override with no image-time one would
# ship the build file, which names a directory on this host. The image would carry neither
# the registry artifact (the override stopped its download) nor a valid path to a
# replacement, and would fail in the first JLL's __init__ on a path that does not exist.
# Failing here costs a build; shipping it would cost a deployment.
if [ -n "${JULIA_DEPOT_OVERRIDES_BUILD:-}" ] && [ -z "${JULIA_DEPOT_OVERRIDES_IMAGE:-}" ]; then
    echo "FAILED: JULIA_DEPOT_OVERRIDES_BUILD is set without JULIA_DEPOT_OVERRIDES_IMAGE," >&2
    echo "        which would ship this host's paths in the image. Set both." >&2
    exit 1
fi

# Relative inside the tar either way; a leading slash is accepted and dropped.
depot_prefix="${JULIA_DEPOT_IMAGE_PREFIX:-opt/julia-depot}"
depot_prefix="${depot_prefix#/}"
contents="${JULIA_DEPOT_CONTENTS:-artifacts}"
min_artifacts="${JULIA_DEPOT_MIN_ARTIFACTS:-1}"
src_depot="${JULIA_DEPOT_PATH%%:*}"

fresh="$(mktemp -d)"
stage="$(mktemp -d)"
trap 'rm -rf "$fresh" "$stage"' EXIT

# Package-server credentials, copied by path from the source depot so a private server
# resolves as it does for the developer. They are never echoed, exported or passed as an
# argument, and never enter the layer: only artifacts/, packages/ and compiled/ leave the
# clean depot.
if [ -d "$src_depot/servers" ]; then
    cp -a "$src_depot/servers" "$fresh/servers"
    chmod -R go-rwx "$fresh/servers"
fi

# Copy the registries instead of cloning them, so the action needs only the package server,
# not git access. Copy from every entry of the source path, as Julia reads them: with
# read-only depots behind the written one (julia.depot's read_only_depots), a registry a
# shared depot already had was never installed into the first entry, and without it a private
# registry's packages would not resolve. A registry is a directory or a <name>.toml with its
# tarball; the first entry that has a name wins, matching Julia's search order. Credentials
# come from the first entry only, where Pkg reads them.
declare -A registry_from=()
IFS=: read -r -a src_entries <<<"$JULIA_DEPOT_PATH"
for i in "${!src_entries[@]}"; do
    d="${src_entries[$i]}"
    [ -n "$d" ] && [ -d "$d/registries" ] || continue
    for r in "$d"/registries/*; do
        [ -e "$r" ] || continue
        name="$(basename "$r")"
        name="${name%.tar.gz}"
        name="${name%.toml}"
        [ "${registry_from[$name]:-$i}" = "$i" ] || continue
        registry_from[$name]="$i"
        mkdir -p "$fresh/registries"
        cp -a "$r" "$fresh/registries/"
    done
done

if [ -n "${JULIA_DEPOT_OVERRIDES_BUILD:-}" ]; then
    mkdir -p "$fresh/artifacts"
    cp "$JULIA_DEPOT_OVERRIDES_BUILD" "$fresh/artifacts/Overrides.toml"
fi

echo "==> instantiating the Manifest into a clean depot"
# A source-loaded image needs the sources of weak dependencies. Pkg.instantiate() skips
# them: they are in the manifest but never downloaded. That is fine when a sysimage carries
# the code. Without one, Julia's precompilation walks the manifest's extensions and needs
# the parent package's source ("failed to find source of parent package").
# download_source fetches them.
instantiate='using Pkg; Pkg.instantiate()'
if [ "$contents" = "full" ]; then
    instantiate="$instantiate; Pkg.Operations.download_source(Pkg.Types.Context())"
fi

# Keep the bundled depots on the path. JULIA_DEPOT_PATH set to the fresh directory alone
# drops Julia's default entries, including <julia>/share/julia, where the distribution ships
# the stdlib precompile caches. Without it, `using Pkg` recompiles Pkg into the fresh depot,
# serially, before instantiate starts: 77 s on a fast machine, 200 to 290 s on a CI runner,
# per invocation. Appending the two bundled depots keeps the fresh depot the only writable
# entry while Julia's shipped caches are found. They are named explicitly so the path shows
# what it holds; a trailing colon would expand to the same two (Julia 1.10 and later leave
# ~/.julia out). The layer is unaffected: only artifacts/, packages/ and compiled/ of the
# fresh depot leave here.
julia_prefix="$(cd "$(dirname "$(readlink -f "$JULIA_DEPOT_BIN")")/.." && pwd)"
depot_path="$fresh:$julia_prefix/local/share/julia:$julia_prefix/share/julia"

env_args=(JULIA_DEPOT_PATH="$depot_path" JULIA_PKG_PRECOMPILE_AUTO=0)
if [ -n "${JULIA_PKG_SERVER:-}" ]; then
    env_args+=(JULIA_PKG_SERVER="$JULIA_PKG_SERVER")
fi
env "${env_args[@]}" "$JULIA_DEPOT_BIN" --startup-file=no --project="$proj" -e "$instantiate"

# A project with no JLLs has no artifacts/ at all. The floor below decides whether that is an
# error, and an empty directory keeps the layer's layout the same either way.
mkdir -p "$fresh/artifacts"

n="$(find "$fresh/artifacts" -mindepth 1 -maxdepth 1 -type d | wc -l)"
kb="$(du -sk "$fresh/artifacts" | cut -f1)"
echo "==> $n artifact directories, $((kb / 1024)) MiB"
if [ "$n" -lt "$min_artifacts" ]; then
    echo "FAILED: only $n artifact directories, below JULIA_DEPOT_MIN_ARTIFACTS=$min_artifacts" >&2
    exit 1
fi

if [ -n "${JULIA_DEPOT_OVERRIDES_BUILD:-}" ]; then
    # Hash-keyed entries only: Pkg honours those at download time, so only their presence
    # in artifacts/ means the override did not take effect. Both TOML key spellings, bare and
    # quoted, must match: a missed one skips the check silently, and the image then carries
    # two copies of the artifact and loads the registry one. A file with no hash-keyed
    # entries is valid (UUID and name overrides are resolved at load time), so a match is
    # checked but not required.
    for h in $(sed -nE 's/^[[:space:]]*"?([0-9a-f]{40})"?[[:space:]]*=.*/\1/p' "$JULIA_DEPOT_OVERRIDES_BUILD"); do
        if [ -d "$fresh/artifacts/$h" ]; then
            echo "FAILED: artifact $h was downloaded despite the override" >&2
            exit 1
        fi
    done
fi

mkdir -p "$stage/$depot_prefix"
mv "$fresh/artifacts" "$stage/$depot_prefix/artifacts"
if [ -n "${JULIA_DEPOT_OVERRIDES_IMAGE:-}" ]; then
    cp "$JULIA_DEPOT_OVERRIDES_IMAGE" "$stage/$depot_prefix/artifacts/Overrides.toml"
fi

# Layer contents: the default is artifacts only, for an image whose sysimage carries the
# code and would never read packages/. `full` also ships packages/ (and compiled/, if
# anything produced it), for an image with no sysimage that loads packages from source at
# startup.
case "$contents" in
    artifacts) ;;
    full)
        for d in packages compiled; do
            if [ -d "$fresh/$d" ]; then
                mv "$fresh/$d" "$stage/$depot_prefix/$d"
            fi
        done
        if [ ! -d "$stage/$depot_prefix/packages" ]; then
            echo "FAILED: JULIA_DEPOT_CONTENTS=full but instantiate produced no packages/" >&2
            exit 1
        fi
        ;;
    *)
        echo "FAILED: JULIA_DEPOT_CONTENTS must be 'artifacts' or 'full'" >&2
        exit 1
        ;;
esac

# Deterministic tar: sorted, epoch mtimes, root-owned by number, permissions normalised
# (0755 for directories and executables, 0644 otherwise, whatever Pkg and the umask left).
# Without these the layer digest changes on every build and nothing downstream can be cached
# or compared. The prefix's top directory is archived, so its parents are entries too, with
# the same normalised modes, and a container runtime does not choose modes for them. These
# are the flags of write_layer in image_layers.sh.
echo "==> writing $out"
LC_ALL=C tar --create --file "$out" \
    --format=gnu \
    --sort=name \
    --mtime=@0 \
    --owner=0 --group=0 --numeric-owner \
    --mode='u=rwX,go=rX' \
    --directory "$stage" \
    "${depot_prefix%%/*}"
