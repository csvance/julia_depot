# Recipes

The interface is the `julia` extension and the rules in `julia/image.bzl`. The rules run the
module's scripts for you, and those scripts are internal: their arguments and variables may
change in any release, so a build that calls one directly can break on an upgrade. Where a
recipe below needs something no rule does, it uses only what a depot repository provides,
`env.sh` and `stamp.txt`, and Julia taken by label so that no machine path enters an action key.

## A sysimage

```python
load("@julia_depot//julia:image.bzl", "julia_sysimage")

julia_sysimage(
    name = "app_sysimage",
    project = "Project.toml",
    manifest = "Manifest.toml",
    srcs = glob(["src/**"]),
    depot = "@my_depot",
    julia = "@julia_dist",
    packages = ["MyApp"],
)
```

`bazel build //:app_sysimage` writes `app_sysimage.so`; start Julia with
`julia --sysimage <file>`. The packages come from the depot the fetch already instantiated,
which the build only reads, so it runs sandboxed and is cached like any other action.
`srcs` are the project's own files, staged at their paths relative to `Project.toml`; list
everything the baked packages load, since a file left out is invisible to the build and a
change to it does not rebuild the sysimage.

A build may need a file outside the project, such as a configuration file a package reads
while it is compiled. Put it in `data` and pass its path through `env`: `$(execpath ...)`
expands for `data`, and `{execroot}` to the absolute execution root.

```python
    data = ["//:config.toml"],
    env = {"MY_APP_CONFIG": "{execroot}/$(execpath //:config.toml)"},
```

The default CPU target is the portable list for the target platform, which runs on any CPU of
that architecture and makes the build slower; `cpu_target = "generic"` builds once, for a
baseline CPU. The sysimage is linked by the module's pinned C compiler; see
[the compiler that links it](contract.md#The-compiler-that-links-it) for `cc` and `system_cc`.
For an image, `julia_sysimage_layer` is the same build as a layer; see [Images](images.md).

Beside the sysimage the rule writes `app_sysimage.inputs.json`, its declared inputs by sha256.
The sysimage's own bytes differ between builds, so compare this file instead to check that
two sysimages were built from the same inputs; `--output_groups=inputs` builds it alone. See
[the inputs file](contract.md#The-inputs-file).

## A depot layer for an image

```python
load("@julia_depot//julia:image.bzl", "julia_depot_layer")

julia_depot_layer(
    name = "depot_layer",
    project = "Project.toml",
    manifest = "Manifest.toml",
    depot = "@my_depot",
    julia = "@julia_dist",
)
```

The tar unpacks at `/opt/julia-depot` (`prefix` to change it) and holds `artifacts/` only,
which suffices when a sysimage carries the code. For an image that loads packages from
source, set `contents = "full"` to ship `packages/` too. With `depot`, the registries and
package server credentials of that depot are copied into a clean depot for the instantiate
only; they never reach the layer. Set `JULIA_PKG_SERVER` with `--action_env` if your packages
come from a private server. See [Images](images.md) for the rest of the image.

### Substituting a locally built artifact

When a JLL's registry artifact must be replaced, for instance by a library built from a
patched source, ship the replacement in its own layer at a fixed path and give the depot layer
two override files:

```python
    overrides_build = "build.toml",  # names the directory on the build host
    overrides_image = "image.toml",  # names the path inside the image; this one ships
```

Both are `artifacts/Overrides.toml` files keyed by the artifact's git tree hash. Pkg skips
downloading an artifact whose hash is overridden to an existing directory, so the registry
copy is neither fetched nor shipped, and the build fails if it was downloaded anyway. The
image file is required whenever the build file is set. UUID-keyed overrides are honoured
at load time but do not stop the download, so key by hash.

## A REPL or a server on the pinned environment

An `sh_binary` with `@my_depot//:env.sh` and `@julia_dist//:bin/julia` in `data`, whose
script sources the one and execs the other with `--project` pointing at the real tree
(`BUILD_WORKSPACE_DIRECTORY` under `bazel run`). The depot fetch has already guaranteed
the environment matches the manifest by the time the script runs.

## A private registry

Give the depot a `hook`: an executable run before instantiate with `JULIA_DEPOT_BIN` and
`JULIA_DEPOT_PATH` set, plus any variables named in `hook_environ`, which also become
inputs so a change refetches. The hook adds the registry and writes the package server
credential into the depot. You write the hook; the module knows nothing about what it does.

```python
julia.depot(
    name = "my_depot",
    manifest = "//:Manifest.toml",
    julia = "@julia_dist",
    hook = "//tools:enable_registry.sh",
    hook_environ = ["MY_REGISTRY_TOKEN"],
)
```

## A declared depot instead of the ambient one

By default the depot rule instantiates into whatever `JULIA_DEPOT_PATH` names at fetch time, or
Julia's default. When the environment should live somewhere specific, say per user on a local
disk rather than in an NFS home, declare it:

```python
julia.depot(
    name = "app_depot",
    manifest = "//app:Manifest.toml",
    julia = "@julia_dist",
    dir = "/cache/{USER}/myproject/julia",
)
```

`{HOME}` and `{USER}` expand from the fetch environment and are registered as inputs, so another
user refetches rather than reusing a depot conformed for someone else. The directory is created
before the hook runs, and `env.sh` exports it with a trailing separator so Julia's bundled
depots stay on the path. Consumers that want a writable depot in front of it (a per-sandbox
scratch depot, say) prepend to `JULIA_DEPOT_PATH` after sourcing `env.sh`; Julia writes to the
first entry and reads packages, artifacts and compiled caches from all of them. Pkg reads
package-server credentials (`servers/<host>/auth.toml`) from the first depot only, so a front
depot needs its own copy when the environment resolves through a private server.

## A shared depot behind a declared one

When the host already has a depot that holds most of what the manifest needs, such as a
host-wide one maintained by someone else, stack it behind `dir` so that each user does not
download and precompile it all again:

```python
julia.depot(
    name = "app_depot",
    manifest = "//app:Manifest.toml",
    julia = "@julia_dist",
    dir = "/cache/{USER}/myproject/julia",
    read_only_depots = ["/opt/julia-depot-shared"],
)
```

`env.sh` then exports `/cache/<user>/myproject/julia:/opt/julia-depot-shared:`. Entries
expand like `dir` and need it. Julia reads from every entry and writes only to the first, and
Pkg installs nothing a later entry already has, so the per-user depot holds only what the
shared one lacks. A host without the shared depot fetches into `dir` alone. Whether each
read-only depot exists is an input; its contents are not. If the shared depot is pruned of
something the environment used, refetch with `bazel fetch --force @app_depot`. A refetch
cannot repair a file damaged in place in the shared depot; it must be repaired there.

This is not hermetic. Julia loads what the shared depot holds without checking it against the
Manifest's hashes, so the shared depot is trusted code, and an `artifacts/Overrides.toml` in it
redirects artifacts for every user; see [what is not
hermetic](contract.md#What-is-not-hermetic).

## Loading an image with podman on a host that also has docker

This is not Julia-specific. `rules_oci`'s `oci_load` probes `command -v docker` first and
falls back to podman only when that fails, so on a host where a docker CLI is installed but
its socket is not reachable, the load fails with "permission denied while trying to connect
to the docker API". Name the loader explicitly with a one-line script, exported as a file,
because `loader` must be a single file and an `sh_binary` brings runfiles with it.

```bash
#!/usr/bin/env bash
exec podman "$@"
```

```python
exports_files(["podman.sh"])

oci_load(
    name = "image_load",
    image = ":image",
    loader = ":podman.sh",
    repo_tags = ["my-app:bazel"],
)
```
