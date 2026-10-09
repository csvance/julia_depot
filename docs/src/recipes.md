# Recipes

Every recipe has the same shape: source the depot's `env.sh`, take Julia by label so no
machine path enters an action key, and run a script. Actions that need the depot at its
real path are tagged `no-sandbox`. `local` would also let them see it, but it disables
remote caching too.

The scripts' own variables are spelled `JULIA_DEPOT_*`, beside Julia's `JULIA_DEPOT_PATH`.
The `RULES_JULIA_DEPOT_*` spelling from before 0.1.1 was removed in 0.2.0.

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
    tools = ["@julia_depot//julia:image_depot.sh"],
    cmd = """
set -euo pipefail
. $(location @my_depot//:env.sh)
export JULIA_DEPOT_BIN="$$(cd "$$(dirname $(location @julia_dist//:bin/julia))" && pwd)/julia"
$(location @julia_depot//julia:image_depot.sh) "$$(dirname $(location Manifest.toml))" "$@"
""",
    tags = ["no-sandbox", "requires-network"],
)
```

The tar unpacks at `opt/julia-depot` (`JULIA_DEPOT_IMAGE_PREFIX` to change it) and holds
`artifacts/` only, which suffices when a sysimage carries the code. For an image that loads
packages from source, set `JULIA_DEPOT_CONTENTS=full` to ship `packages/` too. Set
`JULIA_PKG_SERVER` in the command if your packages come from a private server. The script
copies the source depot's registries and server credentials into the clean depot for the
instantiate only; they never reach the layer.

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
        "@julia_depot//julia:sysimage_envs",
        "@julia_depot_cc//:cc",
        "@julia_depot_cc//:bin/cc",
    ],
    outs = ["app.so"],
    tools = ["@julia_depot//julia:sysimage.sh"],
    cmd = """
set -euo pipefail
. $(location @my_depot//:env.sh)
export JULIA_DEPOT_BIN="$$(cd "$$(dirname $(location @julia_dist//:bin/julia))" && pwd)/julia"
export JULIA_DEPOT_SYSIMAGE_PACKAGES="MyApp"
export JULIA_DEPOT_SYSIMAGE_CC="$(location @julia_depot_cc//:bin/cc)"
proj="$$(mktemp -d)"; trap 'rm -rf "$$proj"' EXIT
cp -rL "$$(dirname $(location Manifest.toml))"/. "$$proj"/
$(location @julia_depot//julia:sysimage.sh) "$$proj" auto "$@"
""",
    tags = ["no-sandbox", "requires-network"],
)
```

`auto` selects the PackageCompiler environment shipped for the running Julia's minor
version. The project is copied first because Bazel stages `srcs` as symlinks to the real
files, and PackageCompiler writes into the project it is given.

`@julia_depot_cc` is the module's pinned compiler; import it with
`use_repo(julia, "julia_depot_cc")`, or declare your own with `julia.cc(name = "my_cc", ...)`.
Both its labels go in `srcs`: `bin/cc` is the path the script takes, and `:cc` brings the zig
distribution it runs. `JULIA_DEPOT_SYSIMAGE_CC` is required. Set it to `system` to link with
the host's compiler instead, which prints a warning and makes the result host-dependent, so
keep it out of a shared cache. See [the compiler that links it](contract.md#The-compiler-that-links-it).

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
