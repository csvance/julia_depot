# The contract

## What the Manifest guarantees

A resolved `Manifest.toml` names every registered package by git tree hash and every
artifact by content hash, so it determines the closure. That holds when the manifest has
no `repo-url` entries (git-sourced packages, which Pkg fetches by branch) and when every
JLL's artifacts are hash-pinned in its `Artifacts.toml`, which is the normal state of a
resolved manifest. Path entries are your own source and are Bazel `srcs`, not depot
content. Check your manifest for `repo-url` before relying on this.

Nothing in the module runs Pkg's resolver. A manifest is pinned, never re-resolved.

## The depot rule

`julia.depot` is a repository rule, not a build action, because fetch time is where
hitting the network is legitimate and because the rule's inputs, the manifest, the hook,
and the environment variables it names, are what Bazel keys the fetch on. Change any of
them and the depot is re-conformed.

It runs `instantiate.sh` on the ambient depot (`JULIA_DEPOT_PATH`, or Julia's default),
not a private one: a fresh depot per manifest would mean gigabytes of artifacts on every
change, and the ambient depot already has most of them. The trade is that `compiled/` can
thrash between branches with different manifests. The script refuses a manifest whose
`julia_version` differs from the running Julia, since such a manifest can instantiate and
then behave differently, which is exactly the failure the pin exists to prevent.

The rule produces `env.sh`, which exports `JULIA_DEPOT_PATH` only when the launching
environment set one, and `stamp.txt` with the manifest sha256, Julia version, host
triplet and depot. Julia itself is deliberately not in `env.sh`: consumers take it as a
label, so the file's content, which is part of every downstream action key, carries no
machine-specific path.

## The image script

`image_depot.sh` is the opposite choice, on purpose: it instantiates into a clean depot,
because an image must carry exactly the closure. It does not enumerate artifacts from
`Artifacts.toml` files, because a static walk silently under-counts: packages may augment
the platform with their own code (`HDF5_jll` tags its entries `mpi`), and a plain
`HostPlatform()` then matches nothing and drops the artifact with no error. Letting Pkg
instantiate means Pkg performs the augmented selection.

Two details that cost real time when missed:

- The distribution's bundled depots stay on the depot path. Setting `JULIA_DEPOT_PATH` to
  the fresh directory alone drops `<julia>/share/julia`, where the stdlib precompile
  caches live, and `using Pkg` then recompiles Pkg serially before anything else. The
  script appends exactly the two bundled depots, not a trailing colon, which would also
  pull in the developer's `~/.julia` and let instantiate treat its artifacts as present.
- Nothing is precompiled into the layer. A cache built in the script's temporary depot,
  laid out differently from the image, would not be valid there. `julia_compiled_layer`
  precompiles in a tree with the image's own layout instead, so its caches load unchanged
  from the image's paths; see [Images](images.md).

In `full` mode the script also runs `download_source`, because `Pkg.instantiate` skips
weak dependencies' sources and a source-loaded image then fails precompiling extensions
with "failed to find source of parent package".

## The sysimage script

A sysimage bakes compiled code, not native libraries, so it does not replace the depot
layer: JLLs resolve their artifact directories in `__init__`, at startup. The build
environment PackageCompiler runs in is pinned per Julia minor and checked against the
running Julia before any work starts.
