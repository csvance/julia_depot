# Testing

The tests live in `e2e/`, a separate Bazel module that depends on this one through
`local_path_override`. The suite tests the consumer interface, so it uses the module the
way a consumer does: through `bazel_dep`, the extension, and the repositories it produces.

```bash
cd e2e
bazel test //...
```

No Julia has to be installed: the module fetches and pins the distributions itself. It
resolves against the public package server, pinned in `e2e/.bazelrc`, so a shell pointing
`JULIA_PKG_SERVER` at a private mirror does not change what the tests fetch.

The suite is self-contained: it neither reads nor writes the developer's depots, whatever
`JULIA_DEPOT_PATH` names. Every depot it fetches declares a `dir` of its own under
`~/.julia-depot-e2e`, one per Julia version, which the rule uses in place of the ambient path.
The one exception is the depot that tests the ambient case, a fetch with no `dir`. For it,
`e2e/.bazelrc` pins `JULIA_DEPOT_PATH` empty for repository rules, which Julia reads as unset,
so that depot always lands in Julia's default, `~/.julia`, and holds the two small packages of
the 1.13 test project. `rm -rf ~/.julia-depot-e2e` resets the suite's depots.

Expect a few minutes cold, most of it downloading the Julia distributions and
building the image example's portable sysimage for each version, one at a time, since a sysimage
build declares 8 GiB to Bazel's scheduler; warm, the whole matrix takes a few minutes.

## The matrix

The matrix is every supported Julia version (see [supported versions](julia-versions.md#Supported-versions)),
one `julia_version_tests()` call each in `e2e/tests/BUILD.bazel` and one workflow each,
`.github/workflows/julia-<minor>.yml`, with its own badge in the README. The tests are tagged
`julia<minor>` for the Julia they run, so a CI shard needs only that version's distribution
and depot:

```bash
bazel test $(bazel query "attr(tags, 'julia1_13', tests(//...))")
```

For each version: the distribution is a Julia of that version that can load its own stdlib;
a depot over a manifest resolved under it stamps the right version, manifest hash and depot,
and its `env.sh` exports that same depot and names no Julia binary; a hook runs before
instantiate and sees its `hook_environ`; `image_depot.sh` ships artifacts and no packages in
`artifacts` mode and both in `full`, honours the image prefix and the artifact floor, and
never ships depot credentials; artifact overrides are honoured, and a broken one fails the
build instead of producing an image with two copies of a library; and the module's
PackageCompiler environment for that version instantiates into the version's depot, where the
image example's sysimage, built from it, starts Julia and loads what was baked into it. Across versions, a manifest resolved under one Julia is
refused by the other in both directions, and a PackageCompiler environment pinned to the
wrong minor is refused before any work starts.

The long-term support release runs a reduced set: the distribution, the depot stamp, both
`image_depot.sh` modes, artifact overrides and the wrong-minor refusal. It has no sysimage build,
since the module ships no PackageCompiler environment for it, no hook test, which is the same on
every version, and no image example, which builds a sysimage layer. A `julia_version_tests()`
call without `sysimage_depot_repo` and `hook_depot_repo` is that reduced set.

Each version in the full set also builds the image example in `e2e/image`: the dist, full
depot, compiled and application layers from `julia/image.bzl`, the image environment, and an
`oci_image` assembled from them with `rules_oci` on a digest-pinned Debian base. `rules_oci`
is a dependency of the e2e module only. Every layer entry must be normalised (uid and gid 0,
epoch mtime, 0755 or 0644), the dist and depot layers must come out byte-identical from two
separate actions, the compiled layer the same entries up to the cache file hash, and
`rules_oci`'s config must carry the environment file and the layers in order.
`julia_precompile_test` must pass on the image's layers and must fail, naming what it
compiled, on the same layers without the compiled layer. A sysimage layer over an
artifacts-only depot, whose registry is fetched fresh, must start without precompiling too.
The layers are large: the distribution alone is about a gigabyte per copy, and the
determinism test builds it twice.

The depot attributes that do not depend on the Julia version are tested on 1.12 alone: `dir`,
and `read_only_depots`, whose depot has a hook seed a shared depot behind `dir` before
instantiate. That test checks the exported path and its order, that a missing read-only depot
neither fails the fetch nor is created, that `dir` received none of what the shared depot held,
that the shared depot is unchanged by the fetch, and that `image_depot.sh` on the stacked path
copies the shared depot's registry rather than installing one. Its depots live under
`~/.julia-depot-e2e`.

A second test damages copies of that shared depot after the fetch and checks what loading the
environment does, and whether rerunning `instantiate.sh`, which is what a forced refetch runs,
repairs it: a removed package or artifact fails to load and is repaired, a truncated library
fails to load and is not, corrupted compiled caches are rebuilt into `dir`, and modified package
source and an added `Overrides.toml` load silently. The last two assert the trust described in
[what is not hermetic](contract.md#What-is-not-hermetic), so a Julia that starts verifying
what it loads fails the test, and the contract page should change with it.

One test sits outside the per-version set. The matrix's sysimage tests run over a depot
that already holds PackageCompiler, so on 1.13 `sysimage.sh auto` is also run on an empty
depot of the test's own, and has to install its PackageCompiler environment there before
building. It downloads the General registry and PackageCompiler each time it runs. It links
with the host's compiler, `JULIA_DEPOT_SYSIMAGE_CC=system`, and checks for the warning.

Each version builds one sysimage through the rules, the image example's. Its layer must hold a
sysimage linked by zig's LLD, with no GCC crt files and no glibc symbol newer than 2.17, and
byte for byte the `julia_sysimage` it was given. On 1.13 that sysimage's compiler is a plain
file that checks, inside the build, that `data` and `env` reached it with `$(execpath ...)` and
`{execroot}` expanded, and then hands the link to the pinned compiler, so the same build also
covers those attributes and a compiler given by label; Julia is also started on the file
directly. `sysimage.sh` must refuse to run with no compiler or with a path that is not
executable. Analysis tests in `e2e/image/cc_test.bzl` check what the rule hands the script for
the default compiler, a consumer's own `julia.cc`, a plain-file compiler and `system_cc`, and
that the compiler is among the action's inputs.

The inputs file is tested on 1.13 against sysimages that are never built: a baseline with every
default, a twin of it under another name, whose file must be byte-identical, and two variants
that change only the compiler or only `env`, whose files must differ in that entry alone. Only
their inputs files are built. The test also checks the
recorded Manifest digest and Julia tarball, and that the layer ships the file beside the
sysimage.

`e2e/projects/workspace` is a workspace with one path-package member and its lock in `deploy/`,
fetched with `project`, `project_srcs`, `precompile = False` and an `env` that a hook checks.
An image built from it must start without compiling, and the instantiate step must fail, naming
the fix, for a staged tree missing the member and for a precompile without sources.

`e2e/refetch_test.sh` covers what no test action can: Bazel refetching a depot between two
builds. It appends a comment to a watched file, builds only a sysimage's inputs file, and checks
that the file records the edit, which happens only if the depot refetched and recopied it; then
it restores the file and checks that the record returns to the original. It does this for the
1.13 project's `Project.toml` and for the workspace member's, a `project_srcs` file outside the
Manifest's directory. CI runs it in the 1.13 job after the tests, and it runs by hand from
anywhere.

The scripts the rules run are internal, but several tests drive them directly, because a
failure path such as the wrong-minor refusal is cheaper to reach there than through a rule.

## Before pushing

`tools/check_no_private_refs.sh` greps everything git would publish for internal
hostnames, machine paths and credentials. The patterns are generic and live in
`tools/private_ref_patterns.txt`; site-specific literals go in a file of your own named
by `PRIVATE_REF_PATTERNS_EXTRA`, so that list never has to be published to be enforced.
CI runs it, along with `buildifier -mode=check -lint=warn -r .`.
