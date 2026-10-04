# Recipes

Every recipe has the same shape: source the depot's `env.sh`, take Julia by label so no
machine path enters an action key, and run a script. `no-sandbox` rather than `local` on
the actions that need the depot at its real path: both let the action see it, but `local`
also disables remote caching.

## A depot layer for an image

`julia_depot_layer` in `julia/image.bzl` is this recipe as a rule, alongside the other image
layers; see [Images](images.md). The genrule form below is the script underneath, for a build
that wants to drive it directly.

```python
genrule(
    name = "depot_layer",
    srcs = [
        "Project.toml",
        "Manifest.toml",
        "@my_depot//:env.sh",
        "@julia_dist//:dist",
        "@julia_dist//:bin/julia",
    ],
    outs = ["depot.tar"],
    tools = ["@rules_julia_depot//julia:image_depot.sh"],
    cmd = """
set -euo pipefail
. $(location @my_depot//:env.sh)
export JULIA_BIN="$$(cd "$$(dirname $(location @julia_dist//:bin/julia))" && pwd)/julia"
$(location @rules_julia_depot//julia:image_depot.sh) "$$(dirname $(location Manifest.toml))" "$@"
""",
    tags = ["no-sandbox", "requires-network"],
)
```

The tar unpacks at `opt/julia-depot` (`JULIA_DEPOT_IMAGE_PREFIX` to change it) and holds
`artifacts/` only. That is right when a sysimage carries the code. For an image that loads
packages from source, set `JULIA_DEPOT_CONTENTS=full` to ship `packages/` too. Set
`JULIA_PKG_SERVER` in the command if your packages come from a private server; the script
copies the source depot's registries and server credentials into the clean depot for the
duration of the instantiate and never into the layer.

Stack it with `rules_oci`: a base image, this layer, the Julia distribution as a layer,
and your application, with the depot first in the image's `JULIA_DEPOT_PATH` and the
distribution's bundled depots after it. `julia_image_env` writes that environment for you.

### Substituting a locally built artifact

When a JLL's registry artifact must be replaced, for instance by a library built from a
patched source, ship the replacement in its own layer at a fixed path and pass two
override files:

```
JULIA_DEPOT_OVERRIDES_BUILD=build.toml    # names the directory on the build host
JULIA_DEPOT_OVERRIDES_IMAGE=image.toml    # names the path inside the image; this one ships
```

Both are `artifacts/Overrides.toml` files keyed by the artifact's git tree hash. Pkg skips
downloading an artifact whose hash is overridden to an existing directory, so the registry
copy is neither fetched nor shipped, and the script fails if it was downloaded anyway. The
image file is required whenever the build file is set. UUID-keyed overrides are honoured
at load time but do not stop the download, so key by hash.

## A sysimage

```python
genrule(
    name = "sysimage",
    srcs = glob(["src/**"]) + [
        "Project.toml",
        "Manifest.toml",
        "@my_depot//:env.sh",
        "@julia_dist//:dist",
        "@julia_dist//:bin/julia",
        "@rules_julia_depot//julia:sysimage_envs",
    ],
    outs = ["app.so"],
    tools = ["@rules_julia_depot//julia:sysimage.sh"],
    cmd = """
set -euo pipefail
. $(location @my_depot//:env.sh)
export JULIA_BIN="$$(cd "$$(dirname $(location @julia_dist//:bin/julia))" && pwd)/julia"
export JULIA_SYSIMAGE_PACKAGES="MyApp"
proj="$$(mktemp -d)"; trap 'rm -rf "$$proj"' EXIT
cp -rL "$$(dirname $(location Manifest.toml))"/. "$$proj"/
$(location @rules_julia_depot//julia:sysimage.sh) "$$proj" auto "$@"
""",
    tags = ["no-sandbox", "requires-network"],
)
```

`auto` selects the PackageCompiler environment shipped for the running Julia's minor
version. The project is copied first because Bazel stages `srcs` as symlinks to the real
files, and PackageCompiler writes into the project it is given.

## A REPL or a server on the pinned environment

An `sh_binary` with `@my_depot//:env.sh` and `@julia_dist//:bin/julia` in `data`, whose
script sources the one and execs the other with `--project` pointing at the real tree
(`BUILD_WORKSPACE_DIRECTORY` under `bazel run`). The depot fetch has already guaranteed
the environment matches the manifest by the time the script runs.

## A private registry

Give the depot a `hook`: an executable run before instantiate with `JULIA_BIN` and
`JULIA_DEPOT_PATH` set, plus any variables named in `hook_environ`, which also become
inputs so a change refetches. The hook adds the registry and writes the package server
credential into the depot; it is yours, and the module knows nothing about it.

```python
julia.depot(
    name = "my_depot",
    manifest = "//:Manifest.toml",
    julia = "@julia_dist//:bin/julia",
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
    julia = "@julia_dist//:bin/julia",
    depot = "/cache/{USER}/myproject/julia",
)
```

`{HOME}` and `{USER}` expand from the fetch environment and are registered as inputs, so another
user refetches rather than reusing a depot conformed for someone else. The directory is created
before the hook runs, and `env.sh` exports it with a trailing separator so Julia's bundled depots
stay on the path. Consumers that want a writable depot in front of it (a per-sandbox scratch
depot, say) prepend to `JULIA_DEPOT_PATH` after sourcing `env.sh`; Julia writes to the first entry
and reads packages, artifacts and compiled caches from all of them. Note that Pkg reads
package-server credentials (`servers/<host>/auth.toml`) from the first depot only, so a front
depot needs its own copy when the environment resolves through a private server.

## Loading an image with podman on a host that also has docker

Not Julia-specific, but it costs an afternoon the first time. rules_oci's `oci_load` probes
`command -v docker` first and falls back to podman only when that fails, so on a host where a
docker CLI is installed but its socket is not reachable the probe wins and the load dies with
"permission denied while trying to connect to the docker API". Name the loader instead of
depending on which CLIs happen to be on PATH: a one-line script, exported as a file, because
`loader` must be a single file and an `sh_binary` brings runfiles with it.

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
