#!/usr/bin/env bash
# Build a sysimage for a Manifest-pinned project with PackageCompiler.
#
# Usage: JULIA_DEPOT_SYSIMAGE_PACKAGES="Pkg1 Pkg2" JULIA_DEPOT_SYSIMAGE_CC=<cc> \
#            sysimage.sh <project dir> <build project> <out.so>
#
#   <project dir>    the project whose packages are baked (a copy; see below)
#   <build project>  the PackageCompiler environment, or `auto` to use the one shipped
#                    beside this script for the running Julia's minor version
#                    (sysimage/v1.12, sysimage/v1.13, ...). Under Bazel, `auto` needs
#                    @julia_depot//julia:sysimage_envs among the action's srcs.
#   <out.so>         sysimage path to write
#
# Environment:
#   JULIA_DEPOT_BIN                  the julia to use (falls back to PATH for hand runs)
#   JULIA_DEPOT_SYSIMAGE_PACKAGES    required, space-separated package names to bake
#   JULIA_DEPOT_SYSIMAGE_CC          required, the C compiler that links the sysimage:
#                                    - the path to a julia.cc repository's bin/cc, such as
#                                      the module's own @julia_depot_cc//:bin/cc, which pins
#                                      the compiler and the glibc it links against
#                                    - the path to any other compiler, used as JULIA_CC
#                                    - `system`, PackageCompiler's own choice: JULIA_CC if
#                                      set, otherwise g++, clang++, gcc or clang from PATH.
#                                      The result then depends on the host, so it must not
#                                      reach a cache that other hosts read.
#                                    Under Bazel, a compiler given by path must be among the
#                                    action's inputs (all of @julia_depot_cc//:cc for the
#                                    pinned one), so that it is part of the action's key.
#   JULIA_DEPOT_SYSIMAGE_CPU_TARGET  default: the CPU targets of the official Julia build
#                                    for the running Julia's architecture, so the sysimage
#                                    runs on any host of that architecture and uses the
#                                    best clone for the CPU it lands on. Kept equal to
#                                    PORTABLE_X86_64_CPU_TARGET and
#                                    PORTABLE_AARCH64_CPU_TARGET in image.bzl.
#
# Cost: code baked into a sysimage cannot be revised. Use the sysimage when the baked
# packages do not change while you work, and an ordinary Revise loop when they do.
#
# No precompile trace is used. `create_sysimage` alone bakes the module code and type
# system, which is most of load time. Method specialisations from a --trace-compile run
# would help further but need a representative workload.
#
# Under Bazel, pass a copy of the project directory: srcs are staged as symlinks to the
# real files, so a write to the project would corrupt the real Manifest.toml.
set -euo pipefail

PROJECT_DIR="$1"
BUILD_PROJECT="$2"
OUT="$3"
: "${JULIA_DEPOT_SYSIMAGE_PACKAGES:?set JULIA_DEPOT_SYSIMAGE_PACKAGES to the space-separated packages to bake}"

# The compiler is chosen explicitly, never by falling back to the host's, which would be an
# input no cache key covers.
case "${JULIA_DEPOT_SYSIMAGE_CC:-}" in
    "")
        cat >&2 <<'EOF'
set JULIA_DEPOT_SYSIMAGE_CC to the C compiler that links the sysimage, one of:
  the pinned compiler  the path to @julia_depot_cc//:bin/cc, with @julia_depot_cc//:cc among the inputs
  your own compiler    the path to it, among the inputs
  the host's compiler  system, whose result depends on the host and must not reach a shared cache
EOF
        exit 2
        ;;
    system)
        cat >&2 <<'EOF'
################################################################################
WARNING: JULIA_DEPOT_SYSIMAGE_CC=system links this sysimage with the host's C
compiler and C library, which are not inputs of the build. Another host can
produce a different sysimage from the same inputs, or one that does not load
there. Do not write this result to a cache that other hosts read.
################################################################################
EOF
        ;;
    *)
        [ -f "$JULIA_DEPOT_SYSIMAGE_CC" ] && [ -x "$JULIA_DEPOT_SYSIMAGE_CC" ] || {
            echo "JULIA_DEPOT_SYSIMAGE_CC=$JULIA_DEPOT_SYSIMAGE_CC is not an executable file" >&2
            exit 2
        }
        # PackageCompiler splits JULIA_CC like a shell command line, hence the quoting.
        cc_abs="$(cd "$(dirname "$JULIA_DEPOT_SYSIMAGE_CC")" && pwd)/$(basename "$JULIA_DEPOT_SYSIMAGE_CC")"
        printf -v JULIA_CC '%q' "$cc_abs"
        export JULIA_CC
        ;;
esac
JULIA="${JULIA_DEPOT_BIN:-julia}"

# The PackageCompiler environment must have been resolved under the same Julia minor as
# the one building the sysimage, since PackageCompiler's compat and its precompile cache
# are both keyed on it. `auto` selects by the running Julia. An explicit project is checked
# the same way, so a stale pin fails here and not deep inside PackageCompiler.
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

# Nothing else instantiates this environment, so a fresh depot may lack PackageCompiler
# and its dependencies. Probe for every pinned package without loading any, and instantiate
# only when one is missing, so a warm depot stays quiet and offline. Instantiate from a copy:
# under Bazel the environment is staged read-only from the external tree, and only the
# depot should change. It uses the registries the depot already has and adds none.
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
