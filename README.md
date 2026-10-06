# julia_depot

[![ci](https://github.com/csvance/julia_depot/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/csvance/julia_depot/actions/workflows/ci.yml)
[![julia 1.10](https://github.com/csvance/julia_depot/actions/workflows/julia-1.10.yml/badge.svg?branch=main)](https://github.com/csvance/julia_depot/actions/workflows/julia-1.10.yml)
[![julia 1.12](https://github.com/csvance/julia_depot/actions/workflows/julia-1.12.yml/badge.svg?branch=main)](https://github.com/csvance/julia_depot/actions/workflows/julia-1.12.yml)
[![julia 1.13](https://github.com/csvance/julia_depot/actions/workflows/julia-1.13.yml/badge.svg?branch=main)](https://github.com/csvance/julia_depot/actions/workflows/julia-1.13.yml)
[![docs stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://csvance.github.io/julia_depot/stable/)
[![docs dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://csvance.github.io/julia_depot/dev/)

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

This is not a Julia language ruleset. [rules_julia](https://github.com/periareon/rules_julia)
models Julia code as Bazel targets (`julia_library`, `julia_binary`, `julia_test`) with a Bazel
toolchain; this module instead pins whole environments to the `Manifest.toml` Pkg already
writes, and packages them into images. The two answer different questions.

## The core workflow

1. Resolve your project the ordinary way and commit `Project.toml` and `Manifest.toml`.
2. Declare a Julia and a depot in `MODULE.bazel`:

```python
bazel_dep(name = "julia_depot", version = "0.1.0")
julia = use_extension("@julia_depot//julia:extensions.bzl", "julia")
julia.dist(name = "julia_dist", version = "1.12.7")
julia.depot(
    name = "my_depot",
    manifest = "//:Manifest.toml",
    julia = "@julia_dist",
)
use_repo(julia, "julia_dist", "my_depot")
```

   In a module that others depend on, prefix these names with your module name, since every
   module's names share one namespace; see [repository names](https://csvance.github.io/julia_depot/stable/contract/#Repository-names).

3. Build on it. Fetching `@my_depot` instantiates and precompiles the manifest, checks
   that it was resolved under the Julia you pinned, and produces an `env.sh` to source.
   From there, a genrule or `sh_binary` sources `env.sh`, takes Julia by label, and runs
   whatever you need: your code, `sysimage.sh` for a sysimage, or `image_depot.sh` for a
   clean depot layer to stack into an OCI image; see the [recipes](https://csvance.github.io/julia_depot/stable/recipes/).
4. For an image, the rules in `julia/image.bzl` do the Julia-specific part: the distribution,
   depot, sysimage and precompile-cache layers as deterministic tars, the image's environment,
   and a test that the image starts without compiling anything. You assemble the image with
   rules_oci (or anything else that takes tars); this module does not depend on it. See
   [images](https://csvance.github.io/julia_depot/stable/images/).

Moving to a new Julia is the distribution version plus a re-resolved manifest, nothing
else; see [Julia versions](https://csvance.github.io/julia_depot/stable/julia-versions/). Private registries plug in through the
depot's `hook`; see [a private registry](https://csvance.github.io/julia_depot/stable/recipes/#A-private-registry).


