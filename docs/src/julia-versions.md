# Julia versions

Nothing here requires one Julia version. `julia.dist` fetches any: the sha256 is
looked up for versions the module knows (1.11.9, 1.12.7, 1.13.0) and passed explicitly
otherwise, per platform, from
`https://julialang-s3.julialang.org/bin/checksums/julia-<version>.sha256`:

```python
julia.dist(
    name = "julia_dist",
    version = "1.12.8",
    sha256 = {
        "linux-x86_64": "<sha256 of julia-1.12.8-linux-x86_64.tar.gz>",
        "linux-aarch64": "<sha256 of julia-1.12.8-linux-aarch64.tar.gz>",
    },
)
```
The depot rule pins nothing itself; it enforces that YOUR manifest was resolved under the
Julia you fetched. Moving to a new Julia is therefore one change in two places, the
distribution version and a re-resolved manifest, and a mismatch fails at fetch time with a
message rather than producing a subtly different depot.

The one version-specific thing the module ships is the PackageCompiler environment a
sysimage is built with, because PackageCompiler's compat and precompile cache are keyed
on the Julia minor. There is one per minor under `julia/sysimage/v<major>.<minor>/`, and
`sysimage.sh auto` picks the one matching the running Julia, failing with the list of
available ones when yours is missing.

## Platforms

Linux x86_64 is the supported platform. `julia.dist` downloads the official build for the
host, detected when the distribution is fetched. Linux aarch64 is mapped to its official build
too, with its own CPU target list below, but it is untested and not supported: it may work, and
your mileage may vary. macOS, Windows and other architectures fail with a message saying they
are not supported yet, because the scripts need GNU tar, coreutils and a Linux Julia; the check runs only when a Julia repository is actually fetched, so a host that
never builds a Julia target is unaffected. `url` and `strip_prefix` are templates, so one
declaration serves both architectures, and a mirror too: `{version}` (1.12.7), `{minor}`
(1.12), `{platform}` (`linux-x86_64`) and `{arch_dir}` (`x64`, the directory julialang-s3
files the build under) expand.

The CPU targets follow the architecture: the image rules and `sysimage.sh` default to the
official build's list for it, `PORTABLE_X86_64_CPU_TARGET` or `PORTABLE_AARCH64_CPU_TARGET`;
see [Images](images.md#CPU-targets). The end-to-end suite runs on Linux x86_64 only.

## Adding a Julia version

Four steps, with 1.14 as the example. The first two need that Julia installed locally
(juliaup is the easy way); nothing after them does.

**One.** The PackageCompiler environment for the new minor:

```bash
mkdir -p julia/sysimage/v1.14
cp julia/sysimage/v1.12/Project.toml julia/sysimage/v1.14/
julia +1.14 --project=julia/sysimage/v1.14 -e 'using Pkg; Pkg.instantiate()'
```

**Two.** A test project resolved under that exact Julia, against the PUBLIC server.
`env -u JULIA_PKG_SERVER` matters: a manifest resolved through a private mirror is not one
this repository can publish.

```bash
mkdir -p e2e/projects/v1.14
cp e2e/projects/v1.13/Project.toml e2e/projects/v1.13/BUILD.bazel e2e/projects/v1.14/
env -u JULIA_PKG_SERVER julia +1.14 --project=e2e/projects/v1.14 \
    -e 'using Pkg; Pkg.add([PackageSpec(name = "Bzip2_jll"), PackageSpec(name = "Crayons")])'
```

**Three.** The sha256 for each platform in `_KNOWN_SHA256` in `julia/dist.bzl`.

**Four.** The declarations: four repositories in `e2e/MODULE.bazel` (distribution, depot,
sysimage depot, hook depot), a `julia_version_tests()` call in `e2e/tests/BUILD.bazel`, a
`julia_image_tests()` call in `e2e/image/BUILD.bazel`, a `version_mismatch_test()` call for
each pair worth covering, a copy of
`.github/workflows/julia-1.13.yml` as `julia-1.14.yml` with the version and tag changed,
and its badge beside the others at the top of `README.md`.
