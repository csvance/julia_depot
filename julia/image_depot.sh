#!/usr/bin/env bash
# Build the depot layer for a container image from a Manifest-pinned project.
#
# Usage: image_depot.sh <project dir> <output tar>
#
# Environment:
#   JULIA_DEPOT_BIN               required, the julia to instantiate with
#   JULIA_DEPOT_PATH              required, the SOURCE depot: its registries/ and servers/
#                                 (package-server credentials) are copied into the clean
#                                 depot so instantiate resolves the way the developer does
#   JULIA_PKG_SERVER              optional, passed through to Pkg (default: Pkg's default)
#   JULIA_DEPOT_CONTENTS          artifacts (default) | full, see below
#   JULIA_DEPOT_IMAGE_PREFIX      path of the depot inside the image, default opt/julia-depot
#   JULIA_DEPOT_MIN_ARTIFACTS     sanity floor on artifact directories, default 1
#   JULIA_DEPOT_OVERRIDES_BUILD   optional artifacts/Overrides.toml for the build (see below)
#   JULIA_DEPOT_OVERRIDES_IMAGE   the artifacts/Overrides.toml to ship in the image,
#                                 required whenever the build one is set
#
# JULIA_DEPOT_PATH is Julia's own; the others are this script's, and before 0.1.1 were spelled
# RULES_JULIA_DEPOT_*. The old spelling still works, with a deprecation warning.
#
# WHY A SECOND DEPOT. depot.bzl conforms the developer's ambient depot to the Manifest,
# which is right for building fast on a workstation and wrong for an image: that tree
# holds every project on the machine, of which this one needs a sliver. So the image gets
# its own depot, instantiated from the Manifest into an empty directory.
#
# WHY NOT ENUMERATE THE ARTIFACTS INSTEAD. Because it silently under-counts. A static walk
# of every Artifacts.toml with HostPlatform() misses packages that augment the platform
# with their own code (HDF5_jll ships .pkg/platform_augmentation.jl and tags its entries
# with `mpi`); a plain HostPlatform() matches nothing, drops the artifact with no error,
# and the failure lands in production as a missing native library at first use. Letting
# Pkg instantiate means Pkg performs the augmented selection, so the set is complete and
# minimal by construction. See artifact_paths.jl, which exists to measure, not to decide.
#
# WHY A SYSIMAGE DOES NOT MAKE THIS REDUNDANT. A sysimage carries compiled code, not
# native libraries. JLLWrappers resolves artifact directories in __init__, at startup,
# which is also why the artifacts can live at a different path in the image than they did
# at build time. Pointed at an empty depot, startup dies in the first JLL's __init__.
#
# NO PRECOMPILATION, in either mode. A cache built against this temporary depot, which
# has none of the image's layout around it, is not one the image can trust. A full-mode
# image either pays its precompilation once at first start, or ships the caches of
# julia_compiled_layer (image.bzl), which precompiles in a tree laid out like the image.
#
# ARTIFACT OVERRIDES substitute a locally built artifact for a registry one. Two files,
# because the path differs between build and image: the build-time file names a directory
# on this host and is consulted by Pkg.instantiate, which skips downloading any artifact
# whose HASH is overridden to an existing directory (only hash-keyed overrides have that
# effect; UUID/name overrides are honoured at load time, not at download time); the image
# file names the in-image path and is what ships, and is therefore required whenever the
# build one is set. The build fails if an overridden hash was downloaded anyway, since
# the image would then carry both and load the registry one. Hash keys are read in either
# TOML spelling, bare or quoted.
set -euo pipefail

# DEPRECATED SPELLINGS. Before 0.1.1 these variables were named RULES_JULIA_DEPOT_<name>. The old
# spelling is still read, with a warning, when the new one is unset; it will be removed in a
# release that raises the module's compatibility_level.
for _name in BIN CONTENTS IMAGE_PREFIX MIN_ARTIFACTS OVERRIDES_BUILD OVERRIDES_IMAGE; do
    _old="RULES_JULIA_DEPOT_$_name" _new="JULIA_DEPOT_$_name"
    if [ -z "${!_new+set}" ] && [ -n "${!_old+set}" ]; then
        echo "warning: $_old is deprecated; set $_new instead" >&2
        export "$_new=${!_old}"
    fi
done

proj="${1:?usage: image_depot.sh <project dir> <output tar>}"
out="${2:?usage: image_depot.sh <project dir> <output tar>}"

: "${JULIA_DEPOT_BIN:?JULIA_DEPOT_BIN must be set to the pinned julia}"
: "${JULIA_DEPOT_PATH:?JULIA_DEPOT_PATH must be set; source the depot rule env.sh first}"

# The two override files are a PAIR. A build-time override with no image-time one would
# ship the build file itself, which names a directory on this host: the image would then
# carry neither the registry artifact (the override stopped its download) nor a valid
# path to a replacement, and would die in the first JLL's __init__ with a path that does
# not exist. Refusing here costs a build; the alternative costs a deployment.
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

# Package-server credentials, copied BY PATH from the source depot so a private server
# resolves the way it does for the developer. Never echoed, exported or passed as an
# argument, and never part of the layer: only artifacts/, packages/ and compiled/ leave
# the clean depot.
if [ -d "$src_depot/servers" ]; then
    cp -a "$src_depot/servers" "$fresh/servers"
    chmod -R go-rwx "$fresh/servers"
fi

# The registries, copied rather than re-cloned. Cheap, and it keeps this action from
# depending on git reachability as well as the package server.
if [ -d "$src_depot/registries" ]; then
    cp -a "$src_depot/registries" "$fresh/registries"
fi

if [ -n "${JULIA_DEPOT_OVERRIDES_BUILD:-}" ]; then
    mkdir -p "$fresh/artifacts"
    cp "$JULIA_DEPOT_OVERRIDES_BUILD" "$fresh/artifacts/Overrides.toml"
fi

echo "==> instantiating the Manifest into a clean depot"
# WEAK DEPENDENCIES ARE NOT OPTIONAL IN A SOURCE-LOADED IMAGE. Pkg.instantiate() skips
# them: they are in the manifest but their sources are never downloaded. That is fine when
# a sysimage carries the code, and fatal without one, because Julia's precompilation walks
# the manifest's extensions and needs the PARENT package's source to exist
# ("failed to find source of parent package"). download_source fills them in.
instantiate='using Pkg; Pkg.instantiate()'
if [ "$contents" = "full" ]; then
    instantiate="$instantiate; Pkg.Operations.download_source(Pkg.Types.Context())"
fi

# THE BUNDLED DEPOTS STAY ON THE PATH. Setting JULIA_DEPOT_PATH to the fresh directory
# alone drops Julia's default entries, including <julia>/share/julia, where the
# distribution ships the stdlib precompile caches. Without it, `using Pkg` recompiles Pkg
# into the fresh depot, serially, before instantiate can start: 77 s on a fast machine,
# 200 to 290 s on a CI runner, per invocation. Appending the two bundled depots keeps the
# fresh depot the sole writable entry while the caches shipped with Julia are found. They
# are named rather than left to a trailing colon, which expands to the same two (Julia
# 1.10 and later leave ~/.julia out of it), so the path says exactly what it is. The layer is unaffected: only artifacts/,
# packages/ and compiled/ of the fresh depot leave here.
julia_prefix="$(cd "$(dirname "$(readlink -f "$JULIA_DEPOT_BIN")")/.." && pwd)"
depot_path="$fresh:$julia_prefix/local/share/julia:$julia_prefix/share/julia"

env_args=(JULIA_DEPOT_PATH="$depot_path" JULIA_PKG_PRECOMPILE_AUTO=0)
if [ -n "${JULIA_PKG_SERVER:-}" ]; then
    env_args+=(JULIA_PKG_SERVER="$JULIA_PKG_SERVER")
fi
env "${env_args[@]}" "$JULIA_DEPOT_BIN" --startup-file=no --project="$proj" -e "$instantiate"

if [ ! -d "$fresh/artifacts" ]; then
    echo "FAILED: instantiate produced no artifacts/ in the clean depot" >&2
    exit 1
fi

n="$(find "$fresh/artifacts" -mindepth 1 -maxdepth 1 -type d | wc -l)"
kb="$(du -sk "$fresh/artifacts" | cut -f1)"
echo "==> $n artifact directories, $((kb / 1024)) MiB"
if [ "$n" -lt "$min_artifacts" ]; then
    echo "FAILED: only $n artifact directories, below JULIA_DEPOT_MIN_ARTIFACTS=$min_artifacts" >&2
    exit 1
fi

if [ -n "${JULIA_DEPOT_OVERRIDES_BUILD:-}" ]; then
    # Hash-keyed entries only: those are the ones Pkg honours at DOWNLOAD time, and so
    # the only ones whose presence in artifacts/ means the override did not take. A TOML
    # key may be bare or quoted, and both spellings have to be recognised, because an
    # unrecognised one skips the check silently and the image then carries two copies of
    # the artifact and loads the registry one. A file with no hash-keyed entries at all
    # is legitimate (UUID and name overrides are resolved at load time), so a match is
    # not required, only checked.
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

# WHAT ELSE GOES IN. Default is artifacts only, which is right when a sysimage carries
# the code: packages/ would then be dead weight the image never reads. `full` also ships
# packages/ (and compiled/, if anything produced it), for an image that has NO sysimage
# and therefore loads its packages from source at startup.
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
# Without these the layer digest changes on every build and nothing downstream can be
# cached or compared. The prefix's top directory is what is archived, so its parents are
# entries too, with the same normalised modes, rather than whatever a container runtime
# invents for them. These are the flags of write_layer in image_layers.sh.
echo "==> writing $out"
LC_ALL=C tar --create --file "$out" \
    --format=gnu \
    --sort=name \
    --mtime=@0 \
    --owner=0 --group=0 --numeric-owner \
    --mode='u=rwX,go=rX' \
    --directory "$stage" \
    "${depot_prefix%%/*}"
