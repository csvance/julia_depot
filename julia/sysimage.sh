#!/usr/bin/env bash
# Build a sysimage for a Manifest-pinned project with PackageCompiler.
#
# Usage: JULIA_DEPOT_SYSIMAGE_PACKAGES="Pkg1 Pkg2" sysimage.sh <project dir> <build project> <out.so>
#
#   <project dir>    the project whose packages are baked (a COPY; see below)
#   <build project>  the PackageCompiler environment, or `auto` to use the one shipped
#                    beside this script for the running Julia's minor version
#                    (sysimage/v1.12, sysimage/v1.13, ...). Under Bazel, `auto` needs
#                    @julia_depot//julia:sysimage_envs among the action's srcs.
#   <out.so>         sysimage path to write
#
# Environment:
#   JULIA_DEPOT_BIN                  the julia to use (falls back to PATH for hand runs)
#   JULIA_DEPOT_SYSIMAGE_PACKAGES    required, space-separated package names to bake
#   JULIA_DEPOT_SYSIMAGE_CPU_TARGET  default: the CPU targets of the official Julia build
#                                    for the running Julia's architecture, so the sysimage
#                                    runs on any host of that architecture and uses the
#                                    best clone for the CPU it lands on. Kept equal to
#                                    PORTABLE_X86_64_CPU_TARGET and
#                                    PORTABLE_AARCH64_CPU_TARGET in image.bzl.
#
# Before 0.1.1 these were spelled RULES_JULIA_DEPOT_*. The old spelling still works, with a
# deprecation warning.
#
# WHAT IT COSTS. Code baked into a sysimage cannot be revised. Use the sysimage when the
# baked packages are fixed underneath you, and an ordinary Revise loop when they are not.
#
# WHAT IS NOT IN IT. No precompile trace: `create_sysimage` alone bakes the module code
# and type system, which is the bulk of load time. Method specialisations from a
# --trace-compile run are a further win and need a representative workload.
#
# PASS A COPY of the project directory when running under Bazel: srcs are staged as
# symlinks to the real files, so anything that wrote to the project would corrupt the
# actual Manifest.toml.
set -euo pipefail

# DEPRECATED SPELLINGS. Before 0.1.1 these variables were named RULES_JULIA_DEPOT_<name>. The old
# spelling is still read, with a warning, when the new one is unset; it will be removed in a
# release that raises the module's compatibility_level.
for _name in BIN SYSIMAGE_PACKAGES SYSIMAGE_CPU_TARGET; do
    _old="RULES_JULIA_DEPOT_$_name" _new="JULIA_DEPOT_$_name"
    if [ -z "${!_new+set}" ] && [ -n "${!_old+set}" ]; then
        echo "warning: $_old is deprecated; set $_new instead" >&2
        export "$_new=${!_old}"
    fi
done

PROJECT_DIR="$1"
BUILD_PROJECT="$2"
OUT="$3"
: "${JULIA_DEPOT_SYSIMAGE_PACKAGES:?set JULIA_DEPOT_SYSIMAGE_PACKAGES to the space-separated packages to bake}"
JULIA="${JULIA_DEPOT_BIN:-julia}"

# The PackageCompiler environment must have been resolved under the SAME Julia minor as
# the one building the sysimage: PackageCompiler's own compat and its precompile cache
# are both keyed on it. `auto` selects by the running Julia; an explicit project is
# checked the same way, so a stale pin fails here rather than deep inside PackageCompiler.
minor="$("$JULIA" --startup-file=no -e 'print(VERSION.major, ".", VERSION.minor)')"
if [ "$BUILD_PROJECT" = "auto" ]; then
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    BUILD_PROJECT="$here/sysimage/v$minor"
    if [ ! -f "$BUILD_PROJECT/Manifest.toml" ]; then
        echo "no PackageCompiler environment for Julia $minor in $here/sysimage/" >&2
        echo "available: $(ls -d "$here"/sysimage/v*/ 2>/dev/null | xargs -n1 basename | tr '\n' ' ')" >&2
        echo "add one: cp sysimage/v<other>/Project.toml sysimage/v$minor/ && julia --project=sysimage/v$minor -e 'using Pkg; Pkg.instantiate()'" >&2
        exit 2
    fi
fi
want="$(sed -n 's/^julia_version = "\([0-9]*\.[0-9]*\)\..*/\1/p' "$BUILD_PROJECT/Manifest.toml")"
if [ -n "$want" ] && [ "$want" != "$minor" ]; then
    echo "the PackageCompiler environment $BUILD_PROJECT was resolved under Julia $want but this is Julia $minor" >&2
    exit 2
fi

# The environment being right does not mean its packages are in the depot: nothing else
# instantiates it, so a fresh depot has the Manifest but not PackageCompiler. Probe for
# every pinned package without loading any, and instantiate only when one is missing, so
# a warm depot stays silent and offline. Instantiate from a COPY: under Bazel the
# environment is staged read-only from the external tree, and only the depot should
# change. The registry is whatever the depot already has; none is added here.
missing="$("$JULIA" --startup-file=no --project="$BUILD_PROJECT" -e '
manifest = Base.parsed_toml(joinpath(dirname(Base.active_project()), "Manifest.toml"))
for (name, entries) in manifest["deps"], entry in entries
    haskey(entry, "git-tree-sha1") || continue
    id = Base.PkgId(Base.UUID(entry["uuid"]), name)
    Base.locate_package(id) === nothing && print(name, " ")
end
')"
if [ -n "$missing" ]; then
    echo "installing the PackageCompiler environment for Julia $minor into the depot (missing: ${missing% })" >&2
    env_copy="$(mktemp -d)"
    trap 'rm -rf "$env_copy"' EXIT
    cp "$BUILD_PROJECT/Project.toml" "$BUILD_PROJECT/Manifest.toml" "$env_copy"/
    chmod u+w "$env_copy"/*.toml
    "$JULIA" --startup-file=no --project="$env_copy" -e 'using Pkg; Pkg.instantiate()'
fi

OUT_ABS="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"

"$JULIA" --startup-file=no --project="$BUILD_PROJECT" -e '
using PackageCompiler

project, out = ARGS[1], ARGS[2]
packages = Symbol.(split(ENV["JULIA_DEPOT_SYSIMAGE_PACKAGES"]))

# The portable list for this architecture unless one is given; see the header.
cpu_target = get(ENV, "JULIA_DEPOT_SYSIMAGE_CPU_TARGET", "")
if isempty(cpu_target)
    cpu_target = Sys.ARCH === :x86_64  ? "generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1);x86-64-v4,-rdrnd,base(1)" :
                 Sys.ARCH === :aarch64 ? "generic;cortex-a57;thunderx2t99;carmel,clone_all;apple-m1,base(3);neoverse-512tvb,-rand,-fpac,base(3)" :
                 error("no portable CPU target list for $(Sys.ARCH); set JULIA_DEPOT_SYSIMAGE_CPU_TARGET")
end

# Bake the named packages and, transitively, everything they depend on.
create_sysimage(
    packages;
    project = project,
    sysimage_path = out,
    incremental = true,
    cpu_target = cpu_target,
)
' "$PROJECT_DIR" "$OUT_ABS"
