# The contract

## What the Manifest guarantees

A resolved `Manifest.toml` names every registered package by git tree hash and every
artifact by content hash, so it determines the closure. That holds when the manifest has
no `repo-url` entries (git-sourced packages, which Pkg fetches by branch) and when every
JLL's artifacts are hash-pinned in its `Artifacts.toml`, which is the normal state of a
resolved manifest. Path entries are your own source and are Bazel `srcs`, not depot
content. Check your manifest for `repo-url` before relying on this.

The module never runs Pkg's resolver. A manifest is pinned, never re-resolved.

## The depot rule

`julia.depot` is a repository rule because a fetch may use the network, and because Bazel
keys a fetch on the rule's inputs: the manifest, the hook, the Julia version and the
environment variables it names. Changing any of them re-conforms the depot.

It runs `instantiate.sh` on the declared `dir`, or else on the ambient depot
(`JULIA_DEPOT_PATH`, or Julia's default). A fresh depot per manifest would mean gigabytes of
artifacts on every change, and an existing depot already has most of them. The cost is that `compiled/` can thrash between branches
with different manifests. The script refuses a manifest whose `julia_version` differs from
the running Julia, because such a manifest can instantiate and then behave differently,
the failure the pin exists to prevent.

The rule produces `env.sh`, which always exports `JULIA_DEPOT_PATH`: the depot the fetch
instantiated into, whether declared with `dir`, set in the launching environment, or
Julia's default made explicit, followed by any `read_only_depots`. A hook is given the same
value, and writes, like Pkg, to its first entry. The rule also produces `stamp.txt` with
the manifest sha256, Julia version, host triplet and depot. `env.sh` does not name Julia:
consumers take it as a label from the distribution (`@julia_dist//:bin/julia`). The depot
is the only machine-specific path in the file, and it is per user.

The rule checks that `manifest` is the file Julia instantiates from. Julia prefers a
versioned `Manifest-v<major>.<minor>.toml` beside `Manifest.toml`, and a `Project.toml` can
name another file with `manifest = ...`. The fetch fails unless `manifest` points at the
file Julia uses, so a project can carry one manifest per Julia version, each pinned by its
own `julia.depot`.

The fetch is keyed on the manifest, the hook, the Julia version (through the
distribution's version header), the declared `dir` and `read_only_depots`, whether each
read-only depot exists, and the variables `HOME`, `JULIA_PKG_SERVER`, every `hook_environ`
entry and, when no `dir` is declared, `JULIA_DEPOT_PATH`. It is not keyed on what a
read-only depot holds, because watching a shared depot's whole tree would cost more than
the fetch it guards. A shared depot that loses something the environment relied on needs
`bazel fetch --force`.

### What is not hermetic

The depot rule is not hermetic, by design. The depot is a directory outside Bazel's output
base that the fetch conforms in place: Bazel caches `env.sh` and `stamp.txt`, not the depot,
which `bazel clean --expunge` leaves alone and anything else on the host can change. Two hosts
with the same `MODULE.bazel` and lockfile can have different depot contents, and
`read_only_depots` adds trees the rule neither owns nor watches. The hermetic alternative, a
depot per manifest inside the output base, would download and precompile gigabytes on every
manifest change and share nothing between workspaces or users.

The Manifest decides where Julia looks, not what it finds there. It names every package by
tree hash and every artifact by content hash, and Julia looks both up by those names in every
depot on the path. Pkg checks the hash when it downloads, and nothing checks it again when
Julia loads, so a directory under the right name is used as it is. A compiled cache, `.ji` or
pkgimage `.so`, is reused when Julia's staleness check passes, which compares its sources,
dependencies and flags, not its bits. A depot on the path is therefore trusted the way any
binary you run is: a shared depot's maintainer supplies code you load. What is guaranteed is
that a missing package or artifact, for example one pruned from a shared depot, fails to load
instead of resolving to some other version, and that a forced refetch installs it into `dir`.
A damaged one is different. Pkg treats a directory that exists as installed, so a refetch
leaves a truncated library or a modified source file in place; only repairing the shared
depot, or no longer stacking it, fixes the environment. A corrupted compiled cache is the
exception: Julia rejects it and compiles a fresh one into `dir`. The e2e suite checks each of
these; see [Testing](testing.md).

`artifacts/Overrides.toml` extends this trust further. Julia reads it from every depot on the
path, an earlier depot winning over a later one, and an override can point an artifact at any
directory, under any hash. An `Overrides.toml` in a shared depot therefore changes what loads
for everyone who stacks that depot. Keep shared depots free of one, or treat it as part of
what every consumer builds against.

The image layers differ in what they take from these depots. The depot layer takes nothing but
registries and package server credentials: `image_depot.sh` downloads every package and
artifact again into a clean depot, with only Julia's bundled depots behind it, so Pkg verifies
everything that goes in, except the artifacts an `overrides_build` file substitutes. That
makes it independent of the host's depots, but not hermetic, since it is an action that uses
the network. The compiled layer precompiles offline inside the assembled image, so no host
cache reaches it. The sysimage layer is the exception: it builds from the packages on the
depot path the stamp records, `dir` and any `read_only_depots`, so whatever a shared depot
holds, its `Overrides.toml` included, is in scope for the sysimage.

### Read-only depots

`read_only_depots` stacks depots after `dir`, so the path is `<dir>:<ro1>:<ro2>:...:`, the
trailing separator keeping Julia's bundled depots last. Julia reads packages, artifacts and
compiled caches from every entry and writes only to the first, and Pkg installs nothing some
entry already holds, so `dir` ends up holding only what the read-only depots lack. The rule
writes nothing to them: it neither creates them nor fails when one is missing, since Julia
skips a missing entry and a host may not have the shared depot at all. Julia itself does
update the timestamp of a cache file it loads, in whichever depot, and ignores the failure
where it lacks permission, so a shared depot's files should be read-only to its users at the
filesystem level. The attribute requires `dir`: without one the depot path is the ambient
`JULIA_DEPOT_PATH`, which can already list any number of depots, and the depot written to
would then depend on the shell.

The image side needs no extra support for this. `image_depot.sh` instantiates into a clean
depot whatever the source depot holds, and copies the registries of every entry of the
source path, so a registry that lives only in a shared depot still reaches the instantiate;
the sysimage layer reads the whole path the stamp records.

## Repository names

The `julia` extension is evaluated once for the whole module graph, so the names given to
`julia.dist` and `julia.depot` share one namespace across every module that uses it. Each
name can be declared only once: a second declaration, in any module, fails with an error
naming both modules, even when the two are identical.

The convention that keeps names apart:

- The root module names its repositories freely: `julia_dist`, `my_depot`.
- A module that others depend on prefixes every name it declares with its own module name:
  `my_library_julia`, `my_library_depot`.

A clash fails even when one side is the root module. If the root's declaration won, the
other module would build against a Julia or a manifest it never declared, and a module with
no depot, one that only builds image layers, would ship the root's Julia with no sign of it.

## The depot layer

`julia_depot_layer` makes the opposite choice: it instantiates into a clean depot, because an
image must carry exactly the closure. It does not enumerate artifacts from `Artifacts.toml`
files, because a static walk under-counts: packages may augment the platform with their own
code (`HDF5_jll` tags its entries `mpi`), and a plain `HostPlatform()` then matches nothing
and drops the artifact with no error. Letting Pkg instantiate means Pkg performs the augmented
selection.

Two details are easy to miss:

- The distribution's bundled depots stay on the depot path. Setting `JULIA_DEPOT_PATH` to
  the fresh directory alone drops `<julia>/share/julia`, where the stdlib precompile
  caches live, and `using Pkg` then recompiles Pkg serially before anything else. The
  build appends the two bundled depots by name. A trailing colon would expand to the
  same two (since Julia 1.10 it leaves `~/.julia` out), but naming them keeps the path
  explicit.
- Nothing is precompiled into the layer. A cache built in the build's temporary depot,
  laid out differently from the image, would not be valid there. `julia_compiled_layer`
  precompiles in a tree with the image's own layout instead, so its caches load unchanged
  from the image's paths; see [Images](images.md).

In `full` mode the build also runs `download_source`, because `Pkg.instantiate` skips
weak dependencies' sources and a source-loaded image then fails precompiling extensions
with "failed to find source of parent package".

## The sysimage

`julia_sysimage` writes the sysimage as a file and `julia_sysimage_layer` as an image layer;
both run the same build. A sysimage bakes compiled code, not native libraries, so it does not replace the depot
layer: JLLs resolve their artifact directories in `__init__`, at startup. The build
environment PackageCompiler runs in is pinned per Julia minor and checked against the
running Julia before any work starts.

### The compiler that links it

PackageCompiler links the sysimage with a C compiler. Left to itself it takes the first of g++,
clang++, gcc and clang on the host's `PATH`, and the sysimage then depends on that compiler and
on the host's C library, neither of which is an input of the action. Two hosts with different
compilers would produce different sysimages under the same cache key, and a sysimage linked
against a newer glibc than another host has would not load there. So the compiler is a declared
input, chosen explicitly:

- **Pinned**, the default for `julia_sysimage_layer`: a `julia.cc` repository, zig fetched by
  sha256 and run as `zig cc -target <arch>-linux-gnu.<glibc>`. One tarball holds the compiler,
  the linker and the glibc stubs, so every host links against the same C library. The module
  declares one itself, `@julia_depot_cc`, targeting glibc 2.17 like the official Julia builds;
  a sysimage linked for it loads on any glibc from 2.17 up. Declare your own with `julia.cc`
  for another zig or glibc. The generated `bin/cc` records the zig version, its sha256 and the
  target, so changing any of them changes its digest and with it the action key.
- **Your own**: any executable target or file, as `cc`. It is an input of the action, so
  changing it rebuilds, and it is then yours to keep pinned.
- **The host's**, by opt-in only: `system_cc = True`. The build prints a warning that the
  result depends on the host, and the action is tagged `no-remote-cache` so the result never
  reaches a shared cache.

Nothing falls back to the host's compiler silently.

The pinned compiler only links: PackageCompiler compiles the code with Julia's own LLVM, so the
compiler's part is the link and the C library the sysimage is linked against. That is what it
pins. The precompile caches of `julia_compiled_layer` need no C compiler, since Julia links
them with the `lld` it bundles.
