# Images

`julia/image.bzl` owns what is Julia-specific about putting a depot into an OCI image: the
layers, the environment the image runs with, and a test that it starts without compiling
anything. It does not depend on rules_oci. Each layer rule writes one tar for `oci_image(tars =
[...])`, the environment is a file for `oci_image(env = ...)`, and the image itself is yours:
the base, the application layer, the entrypoint, how it is loaded or pushed.

## The recipe

```python
load(
    "@rules_julia_depot//julia:image.bzl",
    "julia_compiled_layer",
    "julia_depot_layer",
    "julia_dist_layer",
    "julia_image_env",
    "julia_precompile_test",
)
load("@rules_oci//oci:defs.bzl", "oci_image")

# The layout, declared once. Defaults: Julia at /opt/julia, the depot at /opt/julia-depot.
julia_image_env(
    name = "image_env",
    project = "/opt/app",
)

julia_dist_layer(
    name = "julia_layer",
    julia = "@julia_dist",
)

julia_depot_layer(
    name = "depot_layer",
    contents = "full",
    depot = "@my_depot",
    julia = "@julia_dist",
    manifest = "Manifest.toml",
    project = "Project.toml",
)

# The caches for every project the image starts Julia in.
julia_compiled_layer(
    name = "compiled_layer",
    image_env = ":image_env",
    julia = "@julia_dist",
    layers = [":julia_layer", ":depot_layer", ":app_layer"],
    projects = ["/opt/app"],
)

oci_image(
    name = "image",
    base = "@my_base",
    entrypoint = ["julia", "-e", "using MyApp; MyApp.main()"],
    env = ":image_env",
    tars = [":julia_layer", ":depot_layer", ":compiled_layer", ":app_layer"],
)

# The image starts warm, checked on its layers without a container.
julia_precompile_test(
    name = "image_precompile_test",
    image_env = ":image_env",
    julia = "@julia_dist",
    layers = [":julia_layer", ":depot_layer", ":compiled_layer", ":app_layer"],
    projects = ["/opt/app"],
)
```

`:app_layer` is your own: the project's `Project.toml` and `Manifest.toml` at `/opt/app`, and
your code. `e2e/image/` builds exactly this for every Julia version in the test matrix.

## The rules

All layer rules write `<name>.tar` and take `julia`, the distribution from `julia.dist`, e.g. `@julia_dist`.

| rule | what the tar holds | attributes beyond `julia` |
| --- | --- | --- |
| `julia_dist_layer` | the distribution at `prefix`, its own relative symlinks kept | `prefix` (`/opt/julia`) |
| `julia_depot_layer` | a clean depot for the project at `prefix`: `image_depot.sh` as a rule | `project`, `manifest`, `srcs`, `contents` (`artifacts` or `full`), `prefix` (`/opt/julia-depot`), `depot`, `min_artifacts`, `overrides_build`, `overrides_image`, `env` |
| `julia_sysimage_layer` | a PackageCompiler sysimage at `path`: `sysimage.sh` as a rule | `project`, `manifest`, `srcs`, `depot` (required), `packages`, `cpu_target`, `path` (`/opt/julia-sysimage/sys.so`), `env` |
| `julia_compiled_layer` | the depot's `compiled/`, for the entry projects | `image_env`, `layers`, `projects`, `sysimage`, `env` (`{root}` expands to the unpacked tree) |

`julia_image_env` writes `<name>.env` and provides `JuliaImageEnvInfo`. Its attributes are
`julia_prefix`, `depot_prefix`, `extra_depots`, `project`, `load_path`, `cpu_target`, `offline`
(default true), `path` (default true) and `env`. `julia_image_env_vars(...)` returns the same
variables as a dict, for a BUILD file that merges them with its own.

`julia_precompile_test` is a test, with the compiled layer's attributes plus `modules`.

`project` and `manifest` are labels to the two files; the manifest is staged beside the project
wherever it lives, so a production lock kept apart from the development one works. `srcs` are
further project files (a `LocalPreferences.toml`, workspace members) staged at their paths
relative to the `Project.toml`. `depot` is a julia.depot repository, e.g. `@my_depot`: the depot layer
copies its registries and package-server credentials for the instantiate and ships neither, and
without it fetches the registry fresh; the sysimage layer reads the packages that depot already
holds. `env` passes variables to the build, such as what a package's platform augmentation reads
to select an artifact.

The depot and sysimage layers need the network (tagged `requires-network`); set
`JULIA_PKG_SERVER` with `--action_env` to go through a mirror. Every layer action is
`no-remote-exec`, since they read the distribution through its real directory and, for the depot
and sysimage layers, the depot a fetch filled on this host.

## The environment

`julia_image_env` with the defaults and `project = "/opt/app"` writes, on x86_64:

```
JULIA_CPU_TARGET=generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1);x86-64-v4,-rdrnd,base(1)
JULIA_DEPOT_PATH=/opt/julia-depot:/opt/julia/local/share/julia:/opt/julia/share/julia
JULIA_PKG_OFFLINE=true
JULIA_PROJECT=/opt/app
PATH=/opt/julia/bin:$PATH
```

The depot path is in search order. The image's depot comes first, because Julia writes to the
first entry and a cache that turns out stale at run time is rebuilt there. Then `extra_depots`.
Then the two depots the distribution ships inside itself, which hold the stdlib caches; without
them Julia recompiles the stdlib into the first depot. They are named rather than left to a
trailing `:`, which expands to the same two, so the file says exactly what the path is. `$PATH` is expanded by rules_oci against the base
image's own PATH. Variables of your own go in `env`, and are written to the same file.

## Caches that survive the move

Julia validates a cache against its sources by content and records each source relative to the
depot that holds it (`@depot/packages/...`). So `julia_compiled_layer` unpacks the layers into a
temporary tree with the image's layout, precompiles each entry project against the image's depot
path rooted in that tree, and ships the first depot's `compiled/`; the caches then load unchanged
from `/opt`. The same tree runs the image's own Julia when a dist layer is among `layers`.

Sources outside every depot are recorded by absolute path and would be stale in the image. When
the application has packages of its own (a workspace, or a path dependency), list its root in
`extra_depots` so they are recorded relative to it too.

A cache depends on the active project's preferences, which is why `projects` lists every project
the image starts Julia in, the entrypoint, a worker, a healthcheck, and each is precompiled in its
own environment. If the image starts Julia with a sysimage of its own, pass its in-image path as
`sysimage`: caches are only valid against the sysimage they were built with.

## CPU targets

`JULIA_CPU_TARGET` defaults to the official Julia build's list for the target platform's CPU:
`PORTABLE_X86_64_CPU_TARGET` on x86_64, `PORTABLE_AARCH64_CPU_TARGET` on aarch64 (untested,
see [Julia versions](julia-versions.md#Platforms)), both exported from `image.bzl`. A cache
compiled for it carries a clone per target, and Julia picks the best one for the CPU it lands on, so the caches load on any host of that architecture. Compiled for
the build machine's own CPU, Julia's default, they would be rejected on any host whose CPU
differs and recompiled at the first start, the cost the layer exists to remove. The same value
is in the image's environment, so anything compiled at run time is portable too. The sysimage
layer's `cpu_target` has the same default, and `julia_image_env_vars` returns a `select()` over
the two when no `cpu_target` is given.

## The test

`julia_precompile_test` unpacks the layers the way the compiled layer does and, in each entry
project, loads its direct dependencies (and the project itself, when it is a package; `modules`
overrides both) with `JULIA_DEBUG=loading`. It fails when Julia rejects a cache or compiles a
package, which is exactly what a container would otherwise do at its first start. It runs no
container, so it needs no podman or docker, and it can fail: `e2e/image` runs it on an image
without its compiled layer and requires the failure.

A container is still a different place: a package whose `__init__` needs a device, a driver or a
mounted file the test does not have fails there and not here. Give the test what it needs with
`env`, or check the loaded image itself.

## Build-time layers and `{root}`

`env` on `julia_compiled_layer` and `julia_precompile_test` may write `{root}`, which becomes the
directory the layers are unpacked into. Together with a layer that is passed to these rules but
not to `oci_image`, that lets a package load on a build host that lacks something the image's
runtime provides. The case it was made for is a CUDA build of a library that lists
`libcuda.so.1` as a dependency, so loading it fails without a driver: ship the driver stub in a
build-time layer and point the loader at it.

```python
julia_compiled_layer(
    name = "compiled_layer",
    env = {
        "CUDA_VISIBLE_DEVICES": "",
        "LD_LIBRARY_PATH": "{root}/opt/build/cuda-stub",
    },
    layers = [":julia_layer", ":depot_layer", ":app_layer", ":cuda_stub_layer"],
    ...
)
```

The stub then never reaches the image, where the container runtime supplies the real driver.

## Reproducibility

The dist and depot layers are byte-for-byte reproducible: `e2e/image` builds each
twice in separate actions and compares the digests. The compiled layer is normalised the same way
but its bytes are not reproducible: Julia stamps every cache with a build id and names each cache
file with a hash over the paths of the build. Its entries, modes, owners and mtimes are the same
every time, and Bazel caches the action, so its digest only moves when an input does. A sysimage
is not reproducible either, for the same reason.
