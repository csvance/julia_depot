# rules_julia_depot

[![ci](https://github.com/csvance/rules_julia_depot/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/csvance/rules_julia_depot/actions/workflows/ci.yml)
[![julia 1.12](https://github.com/csvance/rules_julia_depot/actions/workflows/julia-1.12.yml/badge.svg?branch=main)](https://github.com/csvance/rules_julia_depot/actions/workflows/julia-1.12.yml)
[![julia 1.13](https://github.com/csvance/rules_julia_depot/actions/workflows/julia-1.13.yml/badge.svg?branch=main)](https://github.com/csvance/rules_julia_depot/actions/workflows/julia-1.13.yml)

Reproducible Julia environments, sysimages and container images with Bazel, pinned to
the `Manifest.toml` you already commit.

## Why these rules

They work with Julia's package manager rather than against it. The unit of pinning is
Pkg's own: a resolved `Manifest.toml`, which already names every package by tree hash
and every artifact by content hash. The rules never re-resolve, never model packages
themselves, and never invent a second lockfile. They hand Pkg your project and make the
result a Bazel input, so everything Pkg understands keeps working unchanged: path
sources, artifact overrides, private registries and package servers, and the workspaces
Julia 1.12 introduced, where several packages share one manifest.

That makes them simple, and simple turns out to be enough for a lot: a developer REPL
on a pinned environment, a sysimage that removes load time, a container image whose
depot holds exactly the closure and nothing else, and a build that refuses to proceed
when the Julia and the manifest disagree instead of producing something subtly wrong.

## The core workflow

1. Resolve your project the ordinary way and commit `Project.toml` and `Manifest.toml`.
2. Declare a Julia and a depot in `MODULE.bazel`:

```python
bazel_dep(name = "rules_julia_depot", version = "0.1.0")
git_override(
    module_name = "rules_julia_depot",
    remote = "https://github.com/csvance/rules_julia_depot.git",
    commit = "<commit>",
)

julia = use_extension("@rules_julia_depot//julia:extensions.bzl", "julia")
julia.toolchain(name = "julia_dist", version = "1.12.7")
julia.depot(
    name = "my_depot",
    manifest = "//:Manifest.toml",
    julia = "@julia_dist//:bin/julia",
)
use_repo(julia, "julia_dist", "my_depot")
```

3. Build on it. Fetching `@my_depot` instantiates and precompiles the manifest, checks
   that it was resolved under the Julia you pinned, and produces an `env.sh` to source.
   From there, a genrule or `sh_binary` sources `env.sh`, takes Julia by label, and runs
   whatever you need: your code, `sysimage.sh` for a sysimage, or `image_depot.sh` for a
   clean depot layer to stack into an OCI image.
4. For an image, the rules in `julia/image.bzl` do the Julia-specific part: the distribution,
   depot, sysimage and precompile-cache layers as deterministic tars, the image's environment,
   and a test that the image starts without compiling anything. You assemble the image with
   rules_oci (or anything else that takes tars); this module does not depend on it.

Moving to a new Julia is the toolchain version plus a re-resolved manifest, nothing
else. Private registries plug in through the depot's `hook`.

## What is in the box

| | |
| --- | --- |
| `julia.toolchain` | an official Julia distribution, fetched and pinned by sha256 |
| `julia.depot` | the Manifest-pinned depot repository, with an optional pre-instantiate hook |
| `//julia:image_depot.sh` | a clean depot as a deterministic image layer, artifacts-only or with packages, with artifact overrides for locally built binaries |
| `//julia:sysimage.sh` | a PackageCompiler sysimage, with a pinned build environment per Julia minor |
| `julia_dist_layer`, `julia_depot_layer`, `julia_sysimage_layer` | the distribution, a clean depot and a sysimage, each as one deterministic image layer |
| `julia_compiled_layer` | precompile caches for the image's entry projects, built for its layout and a portable CPU target list |
| `julia_image_env` | the image's layout declared once, written as the environment file `oci_image` takes |
| `julia_precompile_test` | a test, run on the layers without a container, that the image starts without precompiling |

## Documentation

- [Images](docs/images.md): the image layers, the environment, the precompile test, and the recipe.
- [Recipes](docs/recipes.md): the depot layer, the sysimage, a REPL target, the hook.
- [The contract](docs/contract.md): what the manifest guarantees, what it does not, and how the depot rule and the image script differ.
- [Julia versions](docs/julia-versions.md): what is version-specific, and adding a version.
- [Testing](docs/testing.md): the end-to-end suite and its version matrix.

## License

MIT.
