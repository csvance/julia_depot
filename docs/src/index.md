```@raw html
---
layout: home

hero:
  name: julia_depot
  text: Reproducible Julia environments with Bazel
  tagline: Depots, sysimages and container images pinned to the Manifest.toml you already commit. The rules never re-resolve, never model packages themselves, and never invent a second lockfile.
  actions:
    - theme: brand
      text: Get started
      link: "#The-core-workflow"
    - theme: alt
      text: Images
      link: /images/
    - theme: alt
      text: View on GitHub
      link: https://github.com/csvance/julia_depot

features:
  - icon: 📌
    title: Pinned by your Manifest
    details: The unit of pinning is Pkg's own resolved `Manifest.toml`, which already names every package by tree hash and every artifact by content hash. See [the contract](/contract/).
  - icon: 🤝
    title: Works with Pkg
    details: Path sources, artifact overrides, private registries, package servers and Julia 1.12 workspaces keep working unchanged, because Pkg does the work.
  - icon: 🛑
    title: Refuses to guess
    details: Fetching a depot checks that the manifest was resolved under the Julia you pinned, and fails with a message instead of producing something subtly different.
    link: /julia-versions/
  - icon: ⚡
    title: Sysimages
    details: A PackageCompiler sysimage from `sysimage.sh`, with a pinned build environment per Julia minor. See the [recipes](/recipes/).
  - icon: 📦
    title: Container images
    details: The distribution, depot, sysimage and precompile caches as deterministic layers for `oci_image`, plus a test that the image starts without compiling.
    link: /images/
  - icon: 🧪
    title: Tested as a consumer
    details: The end-to-end suite is a separate Bazel module that consumes these rules through `bazel_dep`, across a matrix of Julia versions.
    link: /testing/
---
```

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

This is not a Julia language ruleset. [`rules_julia`](https://github.com/periareon/rules_julia)
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
   module's names share one namespace; see [the contract](contract.md#Repository-names).

3. Build on it. Fetching `@my_depot` instantiates and precompiles the manifest, checks
   that it was resolved under the Julia you pinned, and produces an `env.sh` to source.
   From there, a genrule or `sh_binary` sources `env.sh`, takes Julia by label, and runs
   whatever you need: your code, `sysimage.sh` for a sysimage, or `image_depot.sh` for a
   clean depot layer to stack into an OCI image.
4. For an image, the rules in `julia/image.bzl` do the Julia-specific part: the distribution,
   depot, sysimage and precompile-cache layers as deterministic tars, the image's environment,
   and a test that the image starts without compiling anything. You assemble the image with
   `rules_oci` (or anything else that takes tars); this module does not depend on it.

Moving to a new Julia is the distribution version plus a re-resolved manifest, nothing
else. Private registries plug in through the depot's `hook`. A host-wide shared depot can sit
read-only behind a per-user one; see [a shared depot](recipes.md#A-shared-depot-behind-a-declared-one).

## What is in the box

In `MODULE.bazel`, from the `julia` extension:

| | |
| --- | --- |
| `julia.dist` | an official Julia distribution, fetched and pinned by sha256 |
| `julia.depot` | the Manifest-pinned depot, with an optional pre-instantiate hook |

In `BUILD` files, from `@julia_depot//julia:image.bzl`:

| | |
| --- | --- |
| `julia_dist_layer`, `julia_depot_layer`, `julia_sysimage_layer` | the distribution, a clean depot and a sysimage, each as one deterministic image layer |
| `julia_compiled_layer` | precompile caches for the image's entry projects, built for its layout and a portable CPU target list |
| `julia_image_env` | the image's layout declared once, written as the environment file `oci_image` takes |
| `julia_precompile_test` | a test, run on the layers without a container, that the image starts without precompiling |

The depot and sysimage layers are `image_depot.sh` and `sysimage.sh` as rules. Both scripts
are public too, for a genrule that needs them outside an image, such as a sysimage for
local development; see [Recipes](recipes.md).

## Where to go next

- [Images](images.md): the image layers, the environment, the precompile test, and the recipe.
- [Recipes](recipes.md): the depot layer, the sysimage, a REPL target, the hook.
- [The contract](contract.md): what the manifest guarantees, what it does not, and how the depot rule and the image script differ.
- [Julia versions](julia-versions.md): what is version-specific, and adding a version.
- [Testing](testing.md): the end-to-end suite and its version matrix.
