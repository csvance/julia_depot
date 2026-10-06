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
the Julia version and the environment variables it names, are what Bazel keys the fetch
on. Change any of them and the depot is re-conformed.

It runs `instantiate.sh` on the ambient depot (`JULIA_DEPOT_PATH`, or Julia's default),
not a private one: a fresh depot per manifest would mean gigabytes of artifacts on every
change, and the ambient depot already has most of them. The trade is that `compiled/` can
thrash between branches with different manifests. The script refuses a manifest whose
`julia_version` differs from the running Julia, since such a manifest can instantiate and
then behave differently, which is exactly the failure the pin exists to prevent.

The rule produces `env.sh`, which always exports `JULIA_DEPOT_PATH`: the depot the fetch
instantiated into, whether declared with `dir`, set in the launching environment, or
Julia's default made explicit, followed by any `read_only_depots`. A hook is given the same
value, and writes, like Pkg, to its first entry. It also produces
`stamp.txt` with the manifest sha256, Julia version, host triplet and depot. Julia itself
is deliberately not in `env.sh`: consumers take it as a label from the distribution
(`@julia_dist//:bin/julia`). The depot is the one machine-specific path in the file, and
it is per user by nature.

The manifest is the file Julia actually instantiates from, and the rule checks that. Julia
prefers a versioned `Manifest-v<major>.<minor>.toml` beside `Manifest.toml`, and a
`Project.toml` can name another file with `manifest = ...`; the fetch fails unless
`manifest` points at the file Julia uses. A project can therefore carry one manifest per
Julia version, each pinned by its own `julia.depot`.

The fetch is keyed on the manifest, the hook, the Julia version (through the
distribution's version header), the declared `dir` and `read_only_depots`, whether each
read-only depot exists, and the variables `HOME`, `JULIA_PKG_SERVER`, every `hook_environ`
entry and, when no `dir` is declared, `JULIA_DEPOT_PATH`. Not on what a read-only depot
holds: watching a shared depot's whole tree would cost more than the fetch it guards, so a
shared depot that loses something the environment relied on needs `bazel fetch --force`.

### Read-only depots

`read_only_depots` stacks depots after `dir`, so the path is `<dir>:<ro1>:<ro2>:...:`, the
trailing separator keeping Julia's bundled depots last. Julia reads packages, artifacts and
compiled caches from every entry and writes only to the first, and Pkg installs nothing some
entry already holds, so `dir` ends up holding only what the read-only depots lack. The rule
writes nothing to them: it neither creates them nor fails when one is missing, since Julia
skips a missing entry and a host may not have the shared depot at all. Julia itself does
update the timestamp of a cache file it loads, in whichever depot, and ignores the failure
where it may not, so a shared depot should be read-only to its users in fact as well as in
name. The attribute requires `dir`: without one the depot path is the ambient
`JULIA_DEPOT_PATH`, which can already list as many depots as it likes, and the depot written
to would then depend on the shell.

The image side needs nothing of its own for this. `image_depot.sh` instantiates into a clean
depot whatever the source depot holds, and copies the registries of every entry of the
source path, so a registry that lives only in a shared depot still reaches the instantiate;
the sysimage layer reads the whole path the stamp records.

## Repository names

The `julia` extension is evaluated once for the whole module graph, so the names given to
`julia.dist` and `julia.depot` share one namespace across every module that uses it. A name
can be declared once: a second declaration, in any module, fails with an error naming both
modules, even when the two are identical.

The convention that keeps names apart:

- The root module names its repositories freely: `julia_dist`, `my_depot`.
- A module that others depend on prefixes every name it declares with its own module name:
  `my_library_julia`, `my_library_depot`.

Neither declaration wins a clash, by design. Had the root's won, the other module would
build against a Julia or a manifest it never declared, and a module with no depot, one that
only builds image layers, would ship the root's Julia with nothing to say so.

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
  script appends the two bundled depots by name. A trailing colon would expand to the
  same two (since Julia 1.10 it leaves `~/.julia` out), but naming them keeps the path
  explicit.
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
