#!/usr/bin/env bash
# Bring a Julia depot into agreement with a project's Manifest, and prove it.
#
# Called by the julia_depot repository rule at fetch time. Writes nothing outside the
# depot and the output file it is given. INTERNAL: its arguments are not part of the
# module's interface and may change in any release.
#
# This runs on the AMBIENT depot (JULIA_DEPOT_PATH, or Julia's default) rather than
# materialising a private content-addressed one: a fresh depot for a large environment
# means tens of gigabytes of artifacts per Manifest change, and the ambient depot already
# has most of them. The trade is that `compiled/` can thrash between branches with
# different Manifests. The image side (image_depot.sh) does build a clean depot, because
# an image must carry exactly the closure and nothing else.
set -euo pipefail

JULIA="${RULES_JULIA_DEPOT_BIN:-julia}"   # the depot rule passes the pinned one; PATH keeps this runnable by hand

PROJECT_DIR="$1"   # directory holding Project.toml
MANIFEST="$2"      # the manifest the rule pins and watches
STAMP_OUT="$3"     # file to write the resolved facts into

"$JULIA" --startup-file=no --project="$PROJECT_DIR" -e '
using Pkg, TOML

pinned = ARGS[1]
isfile(pinned) || error("no manifest at $pinned; this rule pins an existing manifest, it does not resolve one")

# The manifest Julia will actually use is not always Manifest.toml: a versioned
# Manifest-v<major>.<minor>.toml beside it wins, and Project.toml can name another with
# `manifest = ...`. Ask Julia, and refuse unless it is the pinned file, so the file the
# rule watches and stamps is the file Pkg instantiates from.
used = Base.project_file_manifest_path(Base.active_project())
if used === nothing || realpath(used) != realpath(pinned)
    error("Julia $VERSION would instantiate from $(something(used, "no manifest")), not the pinned $pinned; " *
          "point `manifest` at the file Julia uses for this version")
end

m = TOML.parsefile(pinned)
want = get(m, "julia_version", nothing)
have = string(VERSION)

# Fail loudly rather than hand back a subtly wrong environment. A Manifest resolved
# under a different Julia can instantiate and then behave differently, which is the
# failure this pin exists to prevent.
if want !== nothing && want != have
    error("$(basename(pinned)) was resolved under Julia $want but this is Julia $have; " *
          "align the distribution or re-resolve the manifest deliberately")
end

Pkg.instantiate()
Pkg.precompile()
' "$MANIFEST"

# The stamp records what the environment actually is, so a consumer (and a human
# reading a failed build) can see it without re-deriving it.
{
  echo "manifest_sha256=$(sha256sum "$MANIFEST" | cut -d' ' -f1)"
  echo "julia_version=$("$JULIA" --startup-file=no -e 'print(VERSION)')"
  echo "host_triplet=$("$JULIA" --startup-file=no -e 'using Base.BinaryPlatforms; print(triplet(HostPlatform()))')"
  # The rule always sets JULIA_DEPOT_PATH (env.sh exports the same value); a hand run
  # without it records the depot Julia defaults to.
  echo "depot=${JULIA_DEPOT_PATH:-$("$JULIA" --startup-file=no -e 'print(first(DEPOT_PATH))')}"
} > "$STAMP_OUT"
