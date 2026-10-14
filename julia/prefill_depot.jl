# Copy into the clean depot what the source depot already holds of the active Manifest.
#
# Run by image_depot.sh before its instantiate, with the clean depot first on DEPOT_PATH and the
# source depot entries as ARGS. Internal, like the script.
#
# Usage: julia --project=<project> prefill_depot.jl <source depot>...
#
# The fetch has already instantiated the Manifest into the source depot, so the instantiate into
# the clean depot would otherwise download every package and artifact a second time. This copies
# them instead, and the instantiate that follows finds them present. That instantiate stays the
# authority: anything not copied here, for whatever reason, it downloads as before. So a failure
# here costs time and never the layer, and the script exits 0 after a warning.
#
# Copying more than instantiate would install is what could change the layer, so the selection
# is Pkg's own, mirrored from Pkg.instantiate: the packages it installs, and the artifacts
# Operations.collect_artifacts selects for them, which runs a package's .pkg/select_artifacts.jl
# where it has one (see image_depot.sh, "Why Pkg selects the artifacts"). These are Pkg
# internals; image_depot_modes_test.sh compares the layer with one built from an empty source
# depot, on every Julia version the module tests.
#
# Skipped, and left to instantiate:
#   - a package with deps/build.jl, which instantiate builds in place after installing it, so a
#     copy would carry the source depot's build instead of a fresh one
#   - a package tracking a path or a repository, and the stdlibs
#   - an artifact with an override, which instantiate does not download when the override is
#     honoured, and must be seen downloading when it is not
#   - anything whose tree hash does not match the Manifest or the Artifacts.toml, since a source
#     depot is only trusted to be what it claims after a check
# Packages are copied whatever JULIA_DEPOT_CONTENTS is: instantiate needs them either way, and
# the layer ships them only in full mode.

import Artifacts
using Pkg
using Base.BinaryPlatforms: HostPlatform
using Base: SHA1

const Ops = Pkg.Operations
const fresh = first(DEPOT_PATH)
const sources = filter(!isempty, ARGS)

tree_ok(path, hash) = SHA1(Pkg.GitTools.tree_hash(path)) == hash

# Copy src to dst and keep the copy only if its tree hash is `hash`. cp -a keeps modes and links,
# which the tree hash covers, and --reflink makes the copy cheap where the filesystem can.
function copy_verified(src, dst, hash)
    mkpath(dirname(dst))
    run(`cp -a --reflink=auto $src $dst`)
    tree_ok(dst, hash) && return true
    run(`chmod -R u+w $dst`)
    rm(dst; recursive = true)
    @warn "not reused, tree hash does not match: $src"
    return false
end

# What Pkg leaves in a depot directory when it downloads into it, so a copy leaves the same: from
# Julia 1.13, a CACHEDIR.TAG in artifacts/ and packages/, and an empty packages/temp/. Without
# them the layer differs from one built by downloading.
function mark_downloaded(dir; temp = false)
    isdefined(Pkg, :create_cachedir_tag) || return
    mkpath(dir)
    Pkg.create_cachedir_tag(dir)
    temp && mkpath(joinpath(dir, "temp"))
end

# The first source entry holding packages/<name>/<slug>, under either slug Pkg uses.
function find_package(name, uuid, tree_hash)
    for slug in (Base.version_slug(uuid, tree_hash), Base.version_slug(uuid, tree_hash, 4))
        for d in sources
            p = joinpath(d, "packages", name, slug)
            isdir(p) && return p
        end
    end
    return nothing
end

function prefill()
    env = Pkg.Types.EnvCache()
    # Pkg.instantiate() installs these, and selects artifacts for these. Where Pkg has
    # load_all_deps_loadable (1.12 and 1.13 do), instantiate leaves out what the project cannot
    # load, such as weak dependencies nothing pulls in; 1.10 takes the whole manifest.
    pkgs = isdefined(Ops, :load_all_deps_loadable) ? Ops.load_all_deps_loadable(env) :
        Ops.load_all_deps(env)

    roots = String[]
    npkg = 0
    for pkg in pkgs
        Ops.tracking_registered_version(pkg) || continue
        dst = Ops.source_path(env.manifest_file, pkg)
        if isdir(dst)
            push!(roots, dst)
            continue
        end
        src = find_package(pkg.name, pkg.uuid, pkg.tree_hash)
        src === nothing && continue
        # Its Artifacts.toml is read from the source copy even when the package is not copied.
        push!(roots, src)
        isfile(joinpath(src, "deps", "build.jl")) && continue
        mark_downloaded(dirname(dirname(dst)); temp = true)
        if copy_verified(src, joinpath(dirname(dst), basename(src)), pkg.tree_hash)
            npkg += 1
        end
    end
    push!(roots, dirname(env.project_file))

    nart = 0
    bytes = 0
    seen = Set{SHA1}()
    for root in roots, (_, artifacts) in Ops.collect_artifacts(root; platform = HostPlatform())
        for meta in values(artifacts)
            hash = SHA1(meta["git-tree-sha1"])
            hash in seen && continue
            push!(seen, hash)
            Artifacts.query_override(hash) === nothing || continue
            dst = joinpath(fresh, "artifacts", string(hash))
            isdir(dst) && continue
            i = findfirst(d -> isdir(joinpath(d, "artifacts", string(hash))), sources)
            i === nothing && continue
            src = joinpath(sources[i], "artifacts", string(hash))
            mark_downloaded(dirname(dst))
            if copy_verified(src, dst, hash)
                nart += 1
                bytes += parse(Int, first(split(read(`du -sk $dst`, String)))) * 1024
            end
        end
    end
    println("==> reused $npkg packages and $nart artifacts ($(bytes >> 20) MiB) from the source depot")
end

try
    prefill()
catch e
    @warn "could not reuse the source depot; instantiate downloads everything" exception = (e, catch_backtrace())
end
