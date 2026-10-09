#!/usr/bin/env bash
# Conform a Julia depot to a project's Manifest, check the Julia version, and write a stamp.
#
# Called by the julia_depot repository rule at fetch time. Writes nothing outside the depot
# and the output file it is given. Internal: its arguments are not part of the module's
# interface and may change in any release.
#
# It runs on the depot the rule passes in JULIA_DEPOT_PATH (the declared `dir`, the ambient
# path, or Julia's default). A private content-addressed depot per Manifest would mean tens of
# gigabytes of artifacts per Manifest change, most of which the existing depot already has.
# The cost is that `compiled/` can thrash between branches with different Manifests.
# image_depot.sh builds a clean depot, because an image must carry exactly the closure.
#
# The depot path may have several entries (julia.depot's read_only_depots, or an ambient path
# listing more than one). Pkg installs and precompiles into the first entry only, skipping
# whatever a later entry holds, and the stamp records the whole path, since this environment
# may load from any entry.
set -euo pipefail

JULIA="${JULIA_DEPOT_BIN:-julia}"   # the depot rule passes the pinned one; PATH keeps this runnable by hand

PROJECT_DIR="$1"   # directory holding Project.toml
MANIFEST="$2"      # the manifest the rule pins and watches
STAMP_OUT="$3"     # file to write the resolved facts into

"$JULIA" --startup-file=no --project="$PROJECT_DIR" -e '
using Pkg, TOML

pinned = ARGS[1]
isfile(pinned) || error("no manifest at $pinned; this rule pins an existing manifest, it does not resolve one")

# The manifest Julia uses is not always Manifest.toml: a versioned
# Manifest-v<major>.<minor>.toml beside it takes precedence, and Project.toml can name
# another with `manifest = ...`. Ask Julia, and fail unless it is the pinned file, so the
# rule watches and stamps the file Pkg instantiates from.
used = Base.project_file_manifest_path(Base.active_project())
if used === nothing || realpath(used) != realpath(pinned)
    error("Julia $VERSION would instantiate from $(something(used, "no manifest")), not the pinned $pinned; " *
          "point `manifest` at the file Julia uses for this version")
end

m = TOML.parsefile(pinned)
want = get(m, "julia_version", nothing)
have = string(VERSION)

# No julia_version means a manifest older than the Julia 1.7 format, with nothing to check
# the running Julia against. Fail instead of skipping the check, which would leave exactly
# those manifests unverified.
want === nothing && error("$(basename(pinned)) records no julia_version, so it cannot be checked against Julia $have; " *
                          "re-resolve it with this Julia (Pkg.resolve() writes the current format)")

# A Manifest resolved under a different Julia can instantiate and then behave differently.
# This pin exists to prevent that.
if want != have
    error("$(basename(pinned)) was resolved under Julia $want but this is Julia $have; " *
          "align the distribution or re-resolve the manifest")
end

Pkg.instantiate()
Pkg.precompile()
' "$MANIFEST"

# The stamp records the resolved environment, so a consumer, or someone reading a failed
# build, can see it without re-deriving it.
{
  echo "manifest_sha256=$(sha256sum "$MANIFEST" | cut -d' ' -f1)"
  echo "julia_version=$("$JULIA" --startup-file=no -e 'print(VERSION)')"
  echo "host_triplet=$("$JULIA" --startup-file=no -e 'using Base.BinaryPlatforms; print(triplet(HostPlatform()))')"
  # The rule always sets JULIA_DEPOT_PATH (env.sh exports the same value); a hand run
  # without it records the depot Julia defaults to.
  echo "depot=${JULIA_DEPOT_PATH:-$("$JULIA" --startup-file=no -e 'print(first(DEPOT_PATH))')}"
} > "$STAMP_OUT"
