# Julia versions

Nothing here requires one Julia version. `julia.toolchain` fetches any: the sha256 is
looked up for versions the module knows (1.11.9, 1.12.7, 1.13.0) and passed explicitly
otherwise, from `https://julialang-s3.julialang.org/bin/checksums/julia-<version>.sha256`.
The depot rule pins nothing itself; it enforces that YOUR manifest was resolved under the
Julia you fetched. Moving to a new Julia is therefore one change in two places, the
toolchain version and a re-resolved manifest, and a mismatch fails at fetch time with a
message rather than producing a subtly different depot.

The one version-specific thing the module ships is the PackageCompiler environment a
sysimage is built with, because PackageCompiler's compat and precompile cache are keyed
on the Julia minor. There is one per minor under `julia/sysimage/v<major>.<minor>/`, and
`sysimage.sh auto` picks the one matching the running Julia, failing with the list of
available ones when yours is missing.

Linux x86_64 is what this is used with. Other platforms work by passing `sha256` and
`url` to `julia.toolchain`.

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

**Three.** The sha256 in `_KNOWN_SHA256` in `julia/extensions.bzl`.

**Four.** The declarations: four repositories in `e2e/MODULE.bazel` (toolchain, depot,
sysimage depot, hook depot), a `julia_version_tests()` call in `e2e/tests/BUILD.bazel`, a
`version_mismatch_test()` call for each pair worth covering, a copy of
`.github/workflows/julia-1.13.yml` as `julia-1.14.yml` with the version and tag changed,
and its badge beside the others at the top of `README.md`.
