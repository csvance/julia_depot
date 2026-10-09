# Julia versions

## Supported versions

`julia_depot` supports the long-term support release and the two most recent releases. When the
LTS is one of those two, that is two versions. Each supported version has an end-to-end
workflow, `.github/workflows/julia-<minor>.yml`, and its badge in the README; the workflows are
the authoritative list. The LTS runs a reduced set, without a sysimage build; see
[Testing](testing.md#The-matrix).

## Fetching any version

The module does not require a particular Julia version. `julia.dist` fetches any: the sha256 is
looked up for the versions the module knows, listed in `_KNOWN_SHA256` in
[`julia/dist.bzl`](https://github.com/csvance/julia_depot/blob/main/julia/dist.bzl), and passed
explicitly otherwise, per platform, from
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
The depot rule pins no version itself; it checks that your manifest was resolved under the
Julia you fetched. Moving to a new Julia therefore takes two changes, the distribution version
and a re-resolved manifest, and a mismatch fails at fetch time with a message instead of
producing a subtly different depot.

The only version-specific thing the module ships is the PackageCompiler environment a
sysimage is built with, because PackageCompiler's compat and precompile cache are keyed
on the Julia minor. There is one per minor under `julia/sysimage/v<major>.<minor>/`, and
`sysimage.sh auto` picks the one matching the running Julia, failing with the list of
available ones when yours is missing. The minors the module ships one for are the
directories under
[`julia/sysimage/`](https://github.com/csvance/julia_depot/tree/main/julia/sysimage); on any
other minor the distribution, depots and image layers work, and a sysimage needs an
environment added as described below.

## Platforms

Linux `x86_64` is the supported platform. `julia.dist` downloads the official build for the
host, detected when the distribution is fetched. Linux aarch64 is mapped to its official build
too, with its own CPU target list below, but it is untested and unsupported, though it may
work. macOS, Windows and other architectures fail with a message saying they are not supported,
because the scripts need GNU tar, coreutils and a Linux Julia. The check runs only when a
Julia repository is fetched, so a host that never builds a Julia target is unaffected. `url`
and `strip_prefix` are templates, so one declaration serves both architectures, and a mirror
too: `{version}` (1.12.7), `{minor}` (1.12), `{platform}` (`linux-x86_64`) and `{arch_dir}`
(`x64`, the directory julialang-s3 files the build under) expand.

The CPU targets follow the architecture: the image rules and `sysimage.sh` default to the
official build's list for it, `PORTABLE_X86_64_CPU_TARGET` or `PORTABLE_AARCH64_CPU_TARGET`;
see [Images](images.md#CPU-targets). The end-to-end suite runs on Linux `x86_64` only.

## Adding a Julia version

The steps below use 1.14 as the example. The first two need that Julia installed locally
(juliaup is the simplest way); the rest do not.

### 1. The PackageCompiler environment

Resolve one for the new minor, so `sysimage.sh auto` has an environment to select:

```bash
mkdir -p julia/sysimage/v1.14
cp julia/sysimage/v1.12/Project.toml julia/sysimage/v1.14/
julia +1.14 --project=julia/sysimage/v1.14 -e 'using Pkg; Pkg.instantiate()'
```

### 2. The test project

Resolve it under that exact Julia, against the public package server. `env -u JULIA_PKG_SERVER`
is required, because this repository cannot publish a manifest resolved through a private
mirror. Then update the version named in the copied `Project.toml`'s comment.

```bash
mkdir -p e2e/projects/v1.14
cp e2e/projects/v1.13/Project.toml e2e/projects/v1.13/BUILD.bazel e2e/projects/v1.14/
env -u JULIA_PKG_SERVER julia +1.14 --project=e2e/projects/v1.14 \
    -e 'using Pkg; Pkg.add([PackageSpec(name = "Bzip2_jll"), PackageSpec(name = "Crayons")])'
```

### 3. The checksums

Add the sha256 for each platform to `_KNOWN_SHA256` in `julia/dist.bzl`, from
`https://julialang-s3.julialang.org/bin/checksums/julia-<version>.sha256`.

### 4. The declarations

- In `e2e/MODULE.bazel`, four repositories: the distribution, the depot, the sysimage depot and
  the hook depot.
- A `julia_version_tests()` call in `e2e/tests/BUILD.bazel`.
- A `julia_image_tests()` call in `e2e/image/BUILD.bazel`.
- A `version_mismatch_test()` call for each pair of versions worth covering.
- `.github/workflows/julia-1.14.yml`, a copy of `julia-1.13.yml` with the version and tag
  changed.
- Its badge beside the others at the top of `README.md`.

### The reduced set

A version run with the reduced set, as the LTS is, skips step 1. In step 4 it needs only two
repositories, the distribution and the depot, a `julia_version_tests()` call without
`sysimage_depot_repo` and `hook_depot_repo`, and no `julia_image_tests()` call.

### Retiring a version

When a version leaves support, remove the same pieces: its workflow, badge, test calls,
repositories, test project and, if nothing else uses it, its PackageCompiler environment.
