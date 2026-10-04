# Testing

The tests live in `e2e/`, a separate Bazel module that depends on this one through
`local_path_override`. That is deliberate: what is being tested is the consumer
interface, so the tests consume it the way a consumer does, through `bazel_dep`, the
extension, and the repositories it produces.

```bash
cd e2e
bazel test //...
```

Nothing else is needed. The Julia distributions are fetched and pinned by the module
itself, so no Julia has to be installed to run the suite. It resolves against the public
package server, pinned in `e2e/.bazelrc`, so a shell pointing `JULIA_PKG_SERVER` at a
private mirror does not change what the tests fetch.

Expect a few minutes cold, most of it downloading the two Julia distributions and
building two sysimages per version (one for the sysimage tests, one portable one for the image
example); warm, the whole matrix takes a few minutes.

## The matrix

Every Julia version in the matrix (currently 1.12.7 and 1.13.0) gets the same set of
tests, tagged `julia<minor>` for the Julia they run, so a CI shard needs only that
version's toolchain and depot:

```bash
bazel test $(bazel query "attr(tags, 'julia1_13', tests(//...))")
```

For each version: the toolchain produces a Julia of that version that can load its own
stdlib; a depot over a manifest resolved under it stamps the right version, manifest hash
and depot, and its `env.sh` carries no machine path; a hook runs before instantiate and
sees its `hook_environ`; `image_depot.sh` ships artifacts and no packages in `artifacts`
mode and both in `full`, honours the image prefix and the artifact floor, and never ships
depot credentials; artifact overrides are honoured, and a broken one fails the build
instead of producing an image with two copies of a library; and `sysimage.sh auto`
selects that version's PackageCompiler environment, builds an image, and that image
starts and loads what was baked into it. Across versions, a manifest resolved under one
Julia is refused by the other in both directions, and a PackageCompiler environment
pinned to the wrong minor is refused before any work starts.

Each version also builds the image example in `e2e/image`: the dist, full depot, compiled and
application layers from `julia/image.bzl`, the image environment, and an `oci_image` assembled
from them with rules_oci on a digest-pinned Debian base. rules_oci is a dependency of the e2e
module only. Every layer entry must be normalised (uid and gid 0, epoch mtime, 0755 or 0644),
the dist and depot layers must come out byte-identical from two separate actions, the compiled
layer the same entries up to the cache file hash, and rules_oci's config must carry the
environment file and the layers in order. `julia_precompile_test` must pass on the image's layers
and must fail, naming what it compiled, on the same layers without the compiled layer. A
sysimage layer over an artifacts-only depot, whose registry is fetched fresh, must start without
precompiling too. The layers are large: the distribution alone is about a gigabyte per copy, and
the determinism test builds it twice.

One test sits outside the per-version set. The matrix's sysimage tests run over a depot
that already holds PackageCompiler, so on 1.13 `sysimage.sh auto` is also run on an empty
depot of the test's own, and has to install its PackageCompiler environment there before
building. It downloads the General registry and PackageCompiler each time it runs.

## Before pushing

`tools/check_no_private_refs.sh` greps everything git would publish for internal
hostnames, machine paths and credentials. The patterns are generic and live in
`tools/private_ref_patterns.txt`; site-specific literals go in a file of your own named
by `PRIVATE_REF_PATTERNS_EXTRA`, so that list never has to be published to be enforced.
CI runs it, along with `buildifier -mode=check -lint=warn -r .`.
