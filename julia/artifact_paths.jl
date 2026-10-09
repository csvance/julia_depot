# Measurement tool. Do not use it to define an image's artifact layer.
#
# Prints one absolute artifact directory per line for the packages in the active
# manifest, by walking each package's Artifacts.toml.
#
# A static walk is not a superset of what a process loads at runtime. Measured on one
# server with a 210-package manifest:
#
#   static walk, HostPlatform()      17 directories
#   actually resolved at runtime      19 (18 artifacts + the Julia install dir)
#
# The gap is HDF5_jll. It ships `.pkg/platform_augmentation.jl` and tags its artifact
# entries with `mpi`, so selection needs a platform augmented by the package's own
# code. A plain HostPlatform() has no `mpi` tag, matches nothing, and the artifact is
# dropped without an error. Any package may do this, so no fixed platform makes the
# walk complete.
#
# The other difference is benign: the stdlib JLLs (OpenBLAS, LibCURL, Zlib and ten
# more) resolve into the Julia installation directory, not the depot, because they ship
# inside the Julia distribution. The base image provides those, so they are not layer
# content.
#
# To build the layer, instantiate the Manifest into a dedicated empty depot and take
# that depot's artifacts/ whole. Pkg performs the augmented platform selection itself,
# so the result is complete and minimal with no enumeration heuristic. A developer
# depot is large only because it accumulates every project on the machine; a
# Manifest-scoped depot holds one project's.
#
# This script is still useful for measuring the expected size, and for cross-checking a
# built layer against the manifest to catch a depot that was never fully instantiated
# (it reports hashes it could not resolve to a present directory).

using Pkg
using Pkg.Artifacts
using Base.BinaryPlatforms
using TOML

const PLATFORM = HostPlatform()

function artifacts_toml_for(src::AbstractString)
    for name in ("Artifacts.toml", "JuliaArtifacts.toml")
        p = joinpath(src, name)
        isfile(p) && return p
    end
    return nothing
end

function hashes_from(toml_path::AbstractString)
    out = String[]
    dict = Artifacts.load_artifacts_toml(toml_path; pkg_uuid = nothing)
    for (name, entry) in dict
        # A platform-specific artifact is a Vector of per-platform tables; a
        # platform-independent one is a single table.
        if entry isa Vector
            sel = Artifacts.select_downloadable_artifacts(toml_path; platform = PLATFORM)
            haskey(sel, name) && push!(out, sel[name]["git-tree-sha1"])
        elseif entry isa Dict && haskey(entry, "git-tree-sha1")
            push!(out, entry["git-tree-sha1"])
        end
    end
    return out
end

function enumerate_artifacts()
    hashes = String[]
    npkgs = 0
    nwith = 0
    for (uuid, info) in Pkg.dependencies()
        npkgs += 1
        src = info.source
        src === nothing && continue
        isdir(src) || continue
        toml = artifacts_toml_for(src)
        toml === nothing && continue
        nwith += 1
        try
            append!(hashes, hashes_from(toml))
        catch e
            @warn "could not read artifacts for $(info.name)" exception = e
        end
    end

    unique!(hashes)
    paths = String[]
    for h in hashes
        p = try
            Artifacts.artifact_path(Base.SHA1(h))
        catch
            continue
        end
        isdir(p) && push!(paths, p)
    end
    unique!(paths)
    sort!(paths)

    if get(ENV, "ARTIFACT_PATHS_VERBOSE", "0") == "1"
        println(stderr, "packages in manifest: $npkgs, with an Artifacts.toml: $nwith")
        println(stderr, "artifact hashes: $(length(hashes)), resolved to a present dir: $(length(paths))")
        nmissing = length(hashes) - length(paths)
        nmissing > 0 && println(stderr, "NOT PRESENT in the depot: $nmissing (depot not fully instantiated?)")
    end

    return paths
end

for p in enumerate_artifacts()
    println(p)
end
