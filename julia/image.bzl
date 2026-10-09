"""Image layers for a Julia application, and the environment and check that go with them.

    load(
        "@julia_depot//julia:image.bzl",
        "julia_compiled_layer",
        "julia_depot_layer",
        "julia_dist_layer",
        "julia_image_env",
        "julia_precompile_test",
    )

Each layer rule writes one deterministic tar for rules_oci's `oci_image(tars = [...])`: entries
sorted, mtimes zeroed, owned by uid and gid 0, permissions normalised to 0755 or 0644. This module
does not depend on rules_oci and will not; the consumer wires the tars and the environment file
into its own `oci_image`. See docs/src/images.md for the whole recipe.

`julia_image_env` declares the layout once: where Julia, the depot and any other depots live in
the image, their search order, the CPU targets the caches are compiled for, and the active
project. It writes the image's environment as a KEY=VALUE file, which `oci_image(env = ...)`
takes as is. It passes the same facts to `julia_compiled_layer` and `julia_precompile_test`
through `JuliaImageEnvInfo`, so the caches are built for, and checked against, the environment
the image runs with. `julia_image_env_vars` returns the same variables as a dict, for a BUILD
file that merges them with its own.

The rules call image_layers.sh, which wraps image_depot.sh and sysimage.sh. What those scripts
decide is documented there.
"""

# The CPU targets of the official Julia builds, from JuliaCI's julia-buildkite
# (utilities/build_envs.sh). For x86_64, a generic baseline plus clones for Sandy Bridge, Haswell
# and x86-64-v4; for Linux aarch64, a generic baseline plus Cortex-A57, ThunderX2, Carmel, Apple M1
# and Neoverse V1/V2. A cache compiled for the list loads on any host of that architecture and
# uses the best clone for its CPU. A cache compiled for the build machine's CPU (Julia's default,
# "native") is rejected on any host whose CPU differs, and the package is recompiled at startup:
# the cost a compiled layer exists to remove.
#
# The rules default to the list for the target platform's CPU. sysimage.sh carries the same two
# strings as its default, chosen by the running Julia's architecture; change them together.
PORTABLE_X86_64_CPU_TARGET = "generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1);x86-64-v4,-rdrnd,base(1)"
PORTABLE_AARCH64_CPU_TARGET = "generic;cortex-a57;thunderx2t99;carmel,clone_all;apple-m1,base(3);neoverse-512tvb,-rand,-fpac,base(3)"

_X86_64 = Label("@platforms//cpu:x86_64")
_AARCH64 = Label("@platforms//cpu:aarch64")

def _cpu_attrs():
    return {
        "_x86_64": attr.label(default = _X86_64),
        "_aarch64": attr.label(default = _AARCH64),
    }

def _cpu_target(ctx):
    """The rule's cpu_target, or the portable list for the target platform's CPU when unset."""
    if ctx.attr.cpu_target:
        return ctx.attr.cpu_target
    if ctx.target_platform_has_constraint(ctx.attr._x86_64[platform_common.ConstraintValueInfo]):
        return PORTABLE_X86_64_CPU_TARGET
    if ctx.target_platform_has_constraint(ctx.attr._aarch64[platform_common.ConstraintValueInfo]):
        return PORTABLE_AARCH64_CPU_TARGET
    fail("cpu_target: the target platform is neither x86_64 nor aarch64; set cpu_target explicitly")

JuliaImageEnvInfo = provider(
    doc = "The Julia layout of an image and the environment that describes it, from julia_image_env.",
    fields = {
        "env": "dict: every variable the image's environment file holds.",
        "julia_prefix": "string: where the image keeps the Julia distribution, e.g. /opt/julia.",
        "depot_path": "list of strings: JULIA_DEPOT_PATH in search order. Caches are written to the first.",
        "cpu_target": "string: JULIA_CPU_TARGET, which the compiled layer compiles for.",
        "project": "string or None: JULIA_PROJECT, the project Julia starts in.",
    },
)

def _check_absolute(what, path):
    if not path.startswith("/"):
        fail("{} must be an absolute path in the image, got {}".format(what, path))
    return path.rstrip("/") or "/"

def _depot_path(julia_prefix, depot_prefix, extra_depots):
    # The image's depot comes first because Julia writes to it, so a cache that is stale at run
    # time (a mounted, edited package) is rebuilt there. Next come any other depots, typically the
    # application's own root, so its packages are recorded relative to it in the caches and stay
    # valid when the tree moves (see image_layers.sh, unpack_image). Last come the two depots
    # inside the distribution, which hold the stdlib caches; without them Julia recompiles the
    # stdlib it needs into the first depot. They are named instead of left to a trailing separator
    # (which expands to the same two) so the environment file shows the whole path.
    return [depot_prefix] + extra_depots + [julia_prefix + "/local/share/julia", julia_prefix + "/share/julia"]

def julia_image_env_vars(
        julia_prefix = "/opt/julia",
        depot_prefix = "/opt/julia-depot",
        extra_depots = [],
        project = None,
        load_path = None,
        cpu_target = PORTABLE_X86_64_CPU_TARGET,
        offline = True,
        path = True):
    """The environment variables a Julia image needs, as a dict for oci_image's `env`.

    The same variables `julia_image_env` writes, for a BUILD file that merges them with its own:

        env = julia_image_env_vars(project = "/opt/app") | {"MY_SETTING": "1"}

    Args:
      julia_prefix: where the image keeps the Julia distribution (a julia_dist_layer's prefix).
      depot_prefix: where the image keeps the depot (a julia_depot_layer's prefix). Julia writes
        here.
      extra_depots: further depots, searched after `depot_prefix`, such as the application's root when
        it holds packages of its own that the compiled layer caches.
      project: JULIA_PROJECT, the project Julia starts in. Unset when None.
      load_path: JULIA_LOAD_PATH entries. Unset when None, which leaves Julia's default.
      cpu_target: JULIA_CPU_TARGET. Must match the compiled layer's; julia_image_env ensures this
        by passing it the same value. Defaults to the x86_64 list; pass
        PORTABLE_AARCH64_CPU_TARGET for an aarch64 image. This function cannot choose by
        platform, because oci_image takes `env` only as a dict or a label.
      offline: JULIA_PKG_OFFLINE=true, so Pkg in the image never reaches for the network.
      path: prepend Julia's bin/ to the base image's PATH, as `<julia>/bin:$PATH`, which rules_oci
        expands against the base image's own PATH.

    Returns:
      A dict of variable name to value.
    """
    julia_prefix = _check_absolute("julia_prefix", julia_prefix)
    depot_prefix = _check_absolute("depot_prefix", depot_prefix)
    extra_depots = [_check_absolute("extra_depots", d) for d in extra_depots]
    env = {
        "JULIA_DEPOT_PATH": ":".join(_depot_path(julia_prefix, depot_prefix, extra_depots)),
        # Also set at run time. Julia does not need it to accept a cache (it matches the host CPU
        # against the cache's clones), but it makes anything compiled at run time, such as a
        # package recompiled because a mounted volume changed its source, as portable as the
        # baked caches.
        "JULIA_CPU_TARGET": cpu_target,
    }
    if offline:
        env["JULIA_PKG_OFFLINE"] = "true"
    if project:
        env["JULIA_PROJECT"] = _check_absolute("project", project)
    if load_path != None:
        env["JULIA_LOAD_PATH"] = ":".join(load_path)
    if path:
        env["PATH"] = julia_prefix + "/bin:$PATH"
    return env

# --- julia_image_env --------------------------------------------------------------------------

def _julia_image_env_impl(ctx):
    julia_prefix = _check_absolute("julia_prefix", ctx.attr.julia_prefix)
    depot_prefix = _check_absolute("depot_prefix", ctx.attr.depot_prefix)
    extra_depots = [_check_absolute("extra_depots", d) for d in ctx.attr.extra_depots]
    cpu_target = _cpu_target(ctx)
    env = julia_image_env_vars(
        julia_prefix = julia_prefix,
        depot_prefix = depot_prefix,
        extra_depots = extra_depots,
        project = ctx.attr.project or None,
        load_path = ctx.attr.load_path if ctx.attr.load_path else None,
        cpu_target = cpu_target,
        offline = ctx.attr.offline,
        path = ctx.attr.path,
    )
    for k, v in ctx.attr.env.items():
        if k in env:
            fail("env: {} is set by julia_image_env itself; use the attribute that controls it".format(k))
        env[k] = v

    # KEY=VALUE, one per line, sorted: the file format oci_image's `env` reads.
    out = ctx.actions.declare_file(ctx.label.name + ".env")
    ctx.actions.write(out, "".join(["{}={}\n".format(k, env[k]) for k in sorted(env.keys())]))
    return [
        DefaultInfo(files = depset([out])),
        JuliaImageEnvInfo(
            env = env,
            julia_prefix = julia_prefix,
            depot_path = _depot_path(julia_prefix, depot_prefix, extra_depots),
            cpu_target = cpu_target,
            project = env.get("JULIA_PROJECT"),
        ),
    ]

julia_image_env = rule(
    implementation = _julia_image_env_impl,
    doc = """The Julia layout of an image, and the environment file that describes it.

Writes `<name>.env`, one KEY=VALUE per line, which plugs into rules_oci as `oci_image(env =
":<name>")`. Provides JuliaImageEnvInfo, which julia_compiled_layer and julia_precompile_test
take as `image_env`, so the caches are compiled for, and checked against, this environment.
""",
    attrs = _cpu_attrs() | {
        "julia_prefix": attr.string(default = "/opt/julia", doc = "Where the image keeps Julia: a julia_dist_layer's prefix."),
        "depot_prefix": attr.string(default = "/opt/julia-depot", doc = "Where the image keeps the depot: a julia_depot_layer's prefix. Caches are written here."),
        "extra_depots": attr.string_list(doc = "Further depots, after `depot_prefix`. List the application's root here when it holds packages of its own, so their caches are relocatable."),
        "project": attr.string(doc = "JULIA_PROJECT. Unset when empty."),
        "load_path": attr.string_list(doc = "JULIA_LOAD_PATH entries. Unset when empty, which leaves Julia's default."),
        "cpu_target": attr.string(doc = "JULIA_CPU_TARGET, and the targets the compiled layer compiles for. Default: the portable list for the target platform's CPU (PORTABLE_X86_64_CPU_TARGET or PORTABLE_AARCH64_CPU_TARGET)."),
        "offline": attr.bool(default = True, doc = "Set JULIA_PKG_OFFLINE=true."),
        "path": attr.bool(default = True, doc = "Set PATH to <julia>/bin:$PATH, which rules_oci expands against the base image."),
        "env": attr.string_dict(doc = "Further variables for the image, written to the same file. Not applied when caches are built; pass those to the compiled layer's own `env`."),
    },
)

# --- shared ---------------------------------------------------------------------------------

_JULIA_DOC = "The Julia distribution, `@julia_dist` from julia.dist."

def _julia_bin(ctx):
    for f in ctx.files.julia:
        if f.owner.name == "bin/julia":
            return f
    fail("julia: {} has no bin/julia; pass the distribution, e.g. @julia_dist".format(ctx.attr.julia.label))

def _tool_attrs():
    return {
        "_tool": attr.label(
            default = "//julia:image_layers.sh",
            allow_single_file = True,
            executable = True,
            cfg = "exec",
        ),
        "_scripts": attr.label(default = "//julia:image_scripts"),
    }

def _stage_args(ctx):
    """<rel> <file> pairs that rebuild the project tree around Project.toml."""
    project = ctx.file.project
    base = project.short_path.rpartition("/")[0]
    files = [project, ctx.file.manifest]
    pairs = [("Project.toml", project), ("Manifest.toml", ctx.file.manifest)]
    for f in ctx.files.srcs:
        if base and not f.short_path.startswith(base + "/"):
            fail("srcs: {} is not under the project directory {}".format(f.short_path, base))
        rel = f.short_path[len(base) + 1:] if base else f.short_path
        if rel in ("Project.toml", "Manifest.toml"):
            continue
        pairs.append((rel, f))
        files.append(f)
    args = []
    for rel, f in pairs:
        args += [rel, f.path]
    return args, files

def _stamp(ctx):
    if not ctx.attr.depot:
        return None
    for f in ctx.files.depot:
        if f.basename == "stamp.txt":
            return f
    fail("depot: {} has no stamp.txt; pass the julia.depot repository, e.g. @my_depot".format(ctx.attr.depot.label))

def _project_attrs():
    return {
        "project": attr.label(mandatory = True, allow_single_file = ["Project.toml"], doc = "The project's Project.toml."),
        "manifest": attr.label(mandatory = True, allow_single_file = [".toml"], doc = "The Manifest.toml that pins it, staged beside the Project.toml wherever it lives."),
        "srcs": attr.label_list(allow_files = True, doc = "Further project files (LocalPreferences.toml, workspace members), staged at their paths relative to the Project.toml."),
    }

def _layer_run(ctx, out, arguments, inputs, env = {}, network = False, remote_cache = True, mnemonic = "JuliaLayer", message = None):
    # No remote execution: the depot and sysimage layers read the depot a julia.depot fetch filled
    # on this host, and every layer reads the distribution through its real directory. Actions
    # that need no network are still not tagged block-network, because that sandbox needs a
    # network namespace, which fails on hosts that do not allow one.
    reqs = {"no-remote-exec": "1"}
    if network:
        reqs["requires-network"] = "1"
    if not remote_cache:
        reqs["no-remote-cache"] = "1"
    ctx.actions.run(
        executable = ctx.executable._tool,
        arguments = arguments,
        inputs = depset(inputs, transitive = [ctx.attr.julia[DefaultInfo].files, ctx.attr._scripts[DefaultInfo].files]),
        outputs = [out],
        env = env,
        # PATH for tar and coreutils, and anything set with --action_env, such as JULIA_PKG_SERVER.
        use_default_shell_env = True,
        execution_requirements = reqs,
        mnemonic = mnemonic,
        progress_message = message or "Writing Julia layer %{output}",
    )

# --- julia_dist_layer -----------------------------------------------------------------------

def _julia_dist_layer_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".tar")
    _layer_run(
        ctx,
        out,
        ["dist", _julia_bin(ctx).path, _check_absolute("prefix", ctx.attr.prefix), out.path],
        [],
        # About a gigabyte, which a copy from the local distribution repository rebuilds in
        # seconds, faster than a round trip through a remote or disk cache.
        remote_cache = False,
        mnemonic = "JuliaDistLayer",
    )
    return [DefaultInfo(files = depset([out]))]

julia_dist_layer = rule(
    implementation = _julia_dist_layer_impl,
    doc = "The pinned Julia distribution at `prefix`, as one layer. Its own relative symlinks are kept.",
    attrs = _tool_attrs() | {
        "julia": attr.label(mandatory = True, allow_files = True, doc = _JULIA_DOC),
        "prefix": attr.string(default = "/opt/julia", doc = "Where the image keeps Julia. Match julia_image_env's `julia_prefix`."),
    },
)

# --- julia_depot_layer ----------------------------------------------------------------------

def _julia_depot_layer_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".tar")
    stage, files = _stage_args(ctx)
    stamp = _stamp(ctx)
    env = dict(ctx.attr.env)
    env.update({
        "JULIA_DEPOT_CONTENTS": ctx.attr.contents,
        "JULIA_DEPOT_IMAGE_PREFIX": _check_absolute("prefix", ctx.attr.prefix),
        "JULIA_DEPOT_MIN_ARTIFACTS": str(ctx.attr.min_artifacts),
    })
    inputs = list(files)
    if stamp:
        inputs.append(stamp)
    if ctx.file.overrides_build:
        if not ctx.file.overrides_image:
            fail("overrides_build without overrides_image would ship this host's paths; set both")
        env["JULIA_DEPOT_OVERRIDES_BUILD"] = ctx.file.overrides_build.path
        inputs.append(ctx.file.overrides_build)
    if ctx.file.overrides_image:
        env["JULIA_DEPOT_OVERRIDES_IMAGE"] = ctx.file.overrides_image.path
        inputs.append(ctx.file.overrides_image)
    _layer_run(
        ctx,
        out,
        ["depot", _julia_bin(ctx).path, out.path, stamp.path if stamp else "-"] + stage,
        inputs,
        env = env,
        network = True,
        mnemonic = "JuliaDepotLayer",
    )
    return [DefaultInfo(files = depset([out]))]

julia_depot_layer = rule(
    implementation = _julia_depot_layer_impl,
    doc = """A clean depot for the project at `prefix`, as one layer: image_depot.sh as a rule.

The project is instantiated from its Manifest into an empty depot, so the layer holds exactly its
closure. `contents = "artifacts"` ships artifacts/ only, for an image whose code is in a sysimage;
`"full"` ships packages/ too, for an image that loads from source, and is what
julia_compiled_layer needs. Fetches from the package server: set JULIA_PKG_SERVER with
--action_env to use a mirror.
""",
    attrs = _tool_attrs() | _project_attrs() | {
        "julia": attr.label(mandatory = True, allow_files = True, doc = _JULIA_DOC),
        "contents": attr.string(default = "artifacts", values = ["artifacts", "full"], doc = "artifacts: artifacts/ only. full: packages/ as well."),
        "prefix": attr.string(default = "/opt/julia-depot", doc = "Where the image keeps the depot. Match julia_image_env's `depot_prefix`."),
        "min_artifacts": attr.int(default = 1, doc = "Fail below this many artifact directories, to catch a selection that came up empty without an error."),
        "depot": attr.label(allow_files = True, doc = "Optional julia.depot repository, e.g. `@my_depot`. Its registries and package-server credentials are used for the instantiate (never shipped). Without it the registry is fetched fresh."),
        "overrides_build": attr.label(allow_single_file = True, doc = "artifacts/Overrides.toml naming build-host directories; see docs/src/recipes.md."),
        "overrides_image": attr.label(allow_single_file = True, doc = "The artifacts/Overrides.toml that ships, naming in-image paths. Required with overrides_build."),
        "env": attr.string_dict(doc = "Variables for the instantiate, e.g. what a package's platform augmentation reads to select an artifact."),
    },
)

# --- julia_sysimage_layer -------------------------------------------------------------------

def _sysimage_cc(ctx):
    """JULIA_DEPOT_SYSIMAGE_CC for sysimage.sh, and the files the compiler needs as inputs."""
    if ctx.attr.system_cc:
        return "system", []
    files = ctx.files.cc
    for f in files:
        if f.owner.name == "bin/cc":
            return f.path, files
    info = ctx.attr.cc[DefaultInfo]
    exe = info.files_to_run.executable
    if exe:
        return exe.path, files + [exe] + info.default_runfiles.files.to_list()
    if len(files) == 1:
        return files[0].path, files
    fail("cc: {} is neither a julia.cc repository, an executable target nor a single file".format(ctx.attr.cc.label))

def _julia_sysimage_layer_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".tar")
    stage, files = _stage_args(ctx)
    stamp = _stamp(ctx)
    if not ctx.attr.packages:
        fail("packages: name at least one package to bake")
    cc, cc_files = _sysimage_cc(ctx)
    env = dict(ctx.attr.env)
    env.update({
        "JULIA_DEPOT_SYSIMAGE_PACKAGES": " ".join(ctx.attr.packages),
        "JULIA_DEPOT_SYSIMAGE_CPU_TARGET": _cpu_target(ctx),
        "JULIA_DEPOT_SYSIMAGE_CC": cc,
    })
    _layer_run(
        ctx,
        out,
        ["sysimage", _julia_bin(ctx).path, out.path, stamp.path, _check_absolute("path", ctx.attr.path)] + stage,
        files + [stamp] + cc_files,
        env = env,
        # Used only when the depot lacks PackageCompiler and sysimage.sh installs it.
        network = True,
        # The host's compiler is not in the key, so its result must not be shared.
        remote_cache = not ctx.attr.system_cc,
        mnemonic = "JuliaSysimageLayer",
        message = "Building Julia sysimage layer %{output}",
    )
    return [DefaultInfo(files = depset([out]))]

julia_sysimage_layer = rule(
    implementation = _julia_sysimage_layer_impl,
    doc = """A PackageCompiler sysimage at `path`, as one layer: sysimage.sh as a rule.

The packages come from the depot `depot` names, which its julia.depot fetch already instantiated
for this manifest; a scratch depot in front takes anything the build writes. A sysimage does not
replace the depot layer: artifacts are resolved at startup, so ship a julia_depot_layer beside it,
and start Julia with `--sysimage <path>`.

The sysimage is linked by `cc`, by default the module's pinned compiler, so the compiler and the
glibc it links against are inputs of the action. `system_cc = True` uses the host's compiler
instead; the action is then tagged no-remote-cache.
""",
    attrs = _tool_attrs() | _project_attrs() | _cpu_attrs() | {
        "julia": attr.label(mandatory = True, allow_files = True, doc = _JULIA_DOC),
        "depot": attr.label(mandatory = True, allow_files = True, doc = "The julia.depot repository over this manifest, e.g. `@my_depot`."),
        "packages": attr.string_list(mandatory = True, doc = "Packages to bake, with everything they depend on."),
        "cpu_target": attr.string(doc = "The sysimage's CPU targets. Default: the portable list for the target platform's CPU, which costs build time and runs on any host of that architecture."),
        "path": attr.string(default = "/opt/julia-sysimage/sys.so", doc = "Where the image keeps the sysimage."),
        "env": attr.string_dict(doc = "Variables for the build."),
        "cc": attr.label(
            default = Label("@julia_depot_cc"),
            allow_files = True,
            doc = "The C compiler that links the sysimage: a julia.cc repository such as `@my_cc`, or any executable target. Default: the module's own, zig targeting glibc 2.17.",
        ),
        "system_cc": attr.bool(doc = "Link with the host's compiler instead of `cc`. The result depends on the host, so the action is tagged no-remote-cache."),
    },
)

# --- julia_compiled_layer and julia_precompile_test ----------------------------------------

def _image_args(ctx):
    info = ctx.attr.image_env[JuliaImageEnvInfo]
    if not ctx.attr.projects:
        fail("projects: name at least one entry project, as an absolute path in the image")
    args = ["--julia-prefix", info.julia_prefix]
    for d in info.depot_path:
        args += ["--depot", d]
    for p in ctx.attr.projects:
        args += ["--project", _check_absolute("projects", p)]
    if ctx.attr.sysimage:
        args += ["--sysimage", _check_absolute("sysimage", ctx.attr.sysimage)]

    # Passed as flags because `{root}` is known only after the script unpacks the layers. The
    # script expands it and sets the variables.
    for k in sorted(ctx.attr.env.keys()):
        args += ["--env", "{}={}".format(k, ctx.attr.env[k])]
    return info, args

def _image_attrs():
    return {
        "julia": attr.label(mandatory = True, allow_files = True, doc = _JULIA_DOC + " Used when the layers carry no Julia at the image's prefix."),
        "image_env": attr.label(mandatory = True, providers = [JuliaImageEnvInfo], doc = "The julia_image_env the image runs with."),
        "layers": attr.label_list(mandatory = True, allow_files = [".tar"], doc = "The image's layers, in oci_image order: at least the depot layer with packages, and every layer an entry project's files come from."),
        "projects": attr.string_list(mandatory = True, doc = "The entry projects, as absolute paths in the image: every project the image starts Julia in."),
        "sysimage": attr.string(doc = "The sysimage the image starts Julia with, as a path in the image, when it is not Julia's own."),
        "env": attr.string_dict(doc = "Further variables for Julia, e.g. what a package reads in __init__ or to select an artifact. `{root}` in a value is the directory the layers are unpacked into, so a variable can name a file that only a build-time layer carries, such as a driver stub on LD_LIBRARY_PATH."),
    }

def _julia_compiled_layer_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".tar")
    info, args = _image_args(ctx)
    _layer_run(
        ctx,
        out,
        ["compiled", _julia_bin(ctx).path, out.path] + [a for layer in ctx.files.layers for a in ("--layer", layer.path)] + args,
        ctx.files.layers,
        env = {"JULIA_CPU_TARGET": info.cpu_target},
        mnemonic = "JuliaCompiledLayer",
        message = "Precompiling Julia layer %{output}",
    )
    return [DefaultInfo(files = depset([out]))]

julia_compiled_layer = rule(
    implementation = _julia_compiled_layer_impl,
    doc = """The precompile caches for an image's entry projects, as one layer.

The layers are unpacked into one tree with the image's layout and each entry project is
precompiled there, against the image's depot path rooted in that tree, for the image's
JULIA_CPU_TARGET. The caches are written to the first depot's compiled/, which is all the layer
holds, and load unchanged in the image. Precompiling also loads the whole stack for the first
time, so a package that cannot load fails the build instead of a container.

The tar is normalised like every other layer but is not bit-for-bit reproducible: Julia stamps
each cache with a build id and names each cache file with a hash over the build's paths, which
are in a fresh temporary tree. The same packages get caches every time, with the same modes,
owners and mtimes. Bazel caches the action, so the digest is stable while the inputs are.
""",
    attrs = _tool_attrs() | _image_attrs(),
)

def _julia_precompile_test_impl(ctx):
    info, args = _image_args(ctx)
    julia = _julia_bin(ctx)
    words = [ctx.executable._tool.short_path, "check", julia.short_path]
    words += [a for layer in ctx.files.layers for a in ("--layer", layer.short_path)]
    words += args
    if ctx.attr.modules:
        words += ["--modules", " ".join(ctx.attr.modules)]
    launcher = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        launcher,
        "#!/usr/bin/env bash\nset -euo pipefail\nexec {}\n".format(" ".join([_shell_quote(w) for w in words])),
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [ctx.executable._tool] + ctx.files.layers).merge_all([
        ctx.attr.julia[DefaultInfo].default_runfiles,
        ctx.runfiles(transitive_files = ctx.attr.julia[DefaultInfo].files),
        ctx.runfiles(transitive_files = ctx.attr._scripts[DefaultInfo].files),
    ])
    return [
        DefaultInfo(executable = launcher, runfiles = runfiles),
        RunEnvironmentInfo(environment = {"JULIA_CPU_TARGET": info.cpu_target}),
    ]

def _shell_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"

julia_precompile_test = rule(
    implementation = _julia_precompile_test_impl,
    test = True,
    doc = """Tests that the image starts without precompiling, using its layers and no container.

Unpacks the layers into one tree with the image's layout and, in each entry project, loads its
modules with Julia's loading debug output on. Fails when any cache is rejected or any package is
compiled, as a container would do at its first start. Runs the image's own Julia when a
julia_dist_layer is among the layers, and the distribution's otherwise.
""",
    attrs = _tool_attrs() | _image_attrs() | {
        "modules": attr.string_list(doc = "What to load in every entry project. Default: each project's direct dependencies, and the project itself when it is a package."),
    },
)
