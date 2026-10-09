"""Image layers for a Julia application, and the environment and check that go with them.

    load(
        "@julia_depot//julia:image.bzl",
        "julia_compiled_layer",
        "julia_depot_layer",
        "julia_dist_layer",
        "julia_image_env",
        "julia_precompile_test",
        "julia_sysimage",
        "julia_sysimage_layer",
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

`julia_sysimage` is the one rule here that writes no layer: it builds the sysimage as a plain
file, for a build or a test that starts Julia with it directly. `julia_sysimage_layer` ships that
file in an image, so a build that needs both compiles the sysimage once.

The rules call image_layers.sh, which wraps image_depot.sh and sysimage.sh. All three scripts are
internal: the rules are the interface. What the scripts decide is documented there.
"""

load(":depot_info.bzl", _JuliaDepotInfo = "JuliaDepotInfo")

# Re-exported: the provider a julia.depot repository's default target carries.
JuliaDepotInfo = _JuliaDepotInfo

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

def _depot(ctx):
    return ctx.attr.depot[JuliaDepotInfo]

def _stage_pairs(ctx):
    """(rel, file) pairs that rebuild the project tree around Project.toml.

    The Project.toml, Manifest and project_srcs are the depot's own copies, the ones it was
    fetched for; `srcs` are the consumer's files, under the directory the project lives in.
    """
    depot = _depot(ctx)
    base = depot.project_dir
    pairs = [("Project.toml", depot.project), ("Manifest.toml", depot.manifest)]
    pairs += [(s.rel, s.file) for s in depot.project_srcs]
    staged = {rel: True for rel, _ in pairs}
    for f in ctx.files.srcs:
        if base and not f.short_path.startswith(base + "/"):
            fail("srcs: {} is not under the project directory {}".format(f.short_path, base))
        rel = f.short_path[len(base) + 1:] if base else f.short_path
        if rel in staged:
            # The depot's copy, the file it was fetched for, already stands there.
            continue
        pairs.append((rel, f))
    return pairs

def _stage_args(ctx):
    """<rel> <file> arguments that rebuild the project tree, and the files they name."""
    args = []
    files = []
    for rel, f in _stage_pairs(ctx):
        args += [rel, f.path]
        files.append(f)
    return args, files

def _depot_attrs():
    """What a rule that builds from a depot takes: the depot, which brings Julia and the project."""
    return {
        "depot": attr.label(
            mandatory = True,
            providers = [JuliaDepotInfo],
            doc = "The julia.depot repository, e.g. `@my_depot`. It brings the Julia and the Project.toml and Manifest it was fetched for.",
        ),
        "srcs": attr.label_list(allow_files = True, doc = "Further project files (the package's source, LocalPreferences.toml, workspace members), staged at their paths relative to the depot's Project.toml."),
    }

def _sysimage_resources(_os, _inputs_size):
    # A PackageCompiler build holds several gigabytes at its peak. Declared, so Bazel's local
    # scheduler runs as many at once as the machine's memory allows instead of as many as it
    # has cores; a CI runner that started four ran out.
    return {"memory": 8192, "cpu": 2}

def _layer_run(ctx, out, arguments, inputs, julia, env = {}, network = False, remote_cache = True, mnemonic = "JuliaLayer", message = None, resource_set = None):
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
        inputs = depset(inputs, transitive = [julia, ctx.attr._scripts[DefaultInfo].files]),
        outputs = [out],
        env = env,
        # PATH for tar and coreutils, and anything set with --action_env, such as JULIA_PKG_SERVER.
        use_default_shell_env = True,
        execution_requirements = reqs,
        mnemonic = mnemonic,
        progress_message = message or "Writing Julia layer %{output}",
        resource_set = resource_set,
    )

# --- julia_dist_layer -----------------------------------------------------------------------

def _julia_dist_layer_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".tar")
    _layer_run(
        ctx,
        out,
        ["dist", _julia_bin(ctx).path, _check_absolute("prefix", ctx.attr.prefix), out.path],
        [],
        ctx.attr.julia[DefaultInfo].files,
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
    depot = _depot(ctx)
    stamp = None if ctx.attr.fresh_registry else depot.stamp
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
        ["depot", depot.julia_bin.path, out.path, stamp.path if stamp else "-"] + stage,
        inputs,
        depot.julia,
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
    attrs = _tool_attrs() | _depot_attrs() | {
        "contents": attr.string(default = "artifacts", values = ["artifacts", "full"], doc = "artifacts: artifacts/ only. full: packages/ as well."),
        "prefix": attr.string(default = "/opt/julia-depot", doc = "Where the image keeps the depot. Match julia_image_env's `depot_prefix`."),
        "min_artifacts": attr.int(default = 1, doc = "Fail below this many artifact directories, to catch a selection that came up empty without an error."),
        "fresh_registry": attr.bool(doc = "Fetch the registry into the clean depot instead of copying the depot's registries and package-server credentials, which are otherwise used for the instantiate (and never shipped)."),
        "overrides_build": attr.label(allow_single_file = True, doc = "artifacts/Overrides.toml naming build-host directories; see docs/src/recipes.md."),
        "overrides_image": attr.label(allow_single_file = True, doc = "The artifacts/Overrides.toml that ships, naming in-image paths. Required with overrides_build."),
        "env": attr.string_dict(doc = "Variables for the instantiate, e.g. what a package's platform augmentation reads to select an artifact."),
    },
)

# --- julia_sysimage and julia_sysimage_layer ------------------------------------------------

def _sysimage_cc(ctx):
    """The compiler: struct(env, files, kind, identity).

    env is JULIA_DEPOT_SYSIMAGE_CC for sysimage.sh, files what the build needs as inputs, kind
    what the inputs file records, and identity the files whose bytes identify the compiler there.
    A julia.cc repository is identified by bin/cc alone, which records the zig tarball's sha256.
    """
    if ctx.attr.system_cc:
        return struct(env = "system", files = [], kind = "system", identity = [])
    files = ctx.files.cc
    for f in files:
        if f.owner.name == "bin/cc":
            return struct(env = f.path, files = files, kind = "julia.cc", identity = [f])
    info = ctx.attr.cc[DefaultInfo]
    exe = info.files_to_run.executable
    if exe:
        all = files + [exe] + info.default_runfiles.files.to_list()
        return struct(env = exe.path, files = all, kind = "executable", identity = all)
    if len(files) == 1:
        return struct(env = files[0].path, files = files, kind = "file", identity = files)
    fail("cc: {} is neither a julia.cc repository, an executable target nor a single file".format(ctx.attr.cc.label))

def _sysimage_inputs(ctx, out, cc):
    """Writes the inputs file: what the sysimage is built from, the same bytes on any host."""
    config = {
        "cc": cc.kind,
        "cpu_target": _cpu_target(ctx),
        "env": {k: ctx.attr.env[k] for k in sorted(ctx.attr.env)},
        "packages": ctx.attr.packages,
    }
    keyed = [("project/" + rel, f) for rel, f in _stage_pairs(ctx)]
    keyed += [("data/" + str(f.owner), f) for f in ctx.files.data]
    if cc.kind == "julia.cc":
        keyed += [("cc/bin/cc", f) for f in cc.identity]
    else:
        keyed += [("cc/" + str(f.owner), f) for f in cc.identity]

    # The module's own files that decide the build: the scripts and the PackageCompiler
    # environments. image_layers.sh keeps only the environment for the Julia minor.
    for f in ctx.files._scripts:
        if f.owner.name in ("sysimage.sh", "image_layers.sh") or f.owner.name.startswith("sysimage/"):
            keyed.append(("julia_depot/{}/{}".format(f.owner.package, f.owner.name), f))
    seen = {}
    lines = []
    files = []
    for key, f in sorted(keyed, key = lambda kf: kf[0]):
        if key in seen:
            continue
        seen[key] = True
        lines.append("{}\t{}".format(key, f.path))
        files.append(f)
    listing = ctx.actions.declare_file(out.basename + ".files")
    ctx.actions.write(listing, "\n".join(lines) + "\n")
    dist = _depot(ctx).julia_dist
    ctx.actions.run(
        executable = ctx.executable._tool,
        arguments = ["inputs", out.path, dist.path, json.encode(config), listing.path],
        inputs = files + [dist, listing],
        outputs = [out],
        use_default_shell_env = True,
        mnemonic = "JuliaSysimageInputs",
        progress_message = "Writing the inputs of %{output}",
    )

def _sysimage_run(ctx, out, cc):
    """Runs the sysimage build: image_layers.sh sysimage."""
    stage, files = _stage_args(ctx)
    depot = _depot(ctx)
    if not ctx.attr.packages:
        fail("packages: name at least one package to bake")
    env_args = []
    for k, v in ctx.attr.env.items():
        env_args += ["--env", "{}={}".format(k, ctx.expand_location(v, ctx.attr.data))]
    _layer_run(
        ctx,
        out,
        ["sysimage", depot.julia_bin.path, out.path, depot.stamp.path] + env_args + stage,
        files + [depot.stamp] + cc.files + ctx.files.data,
        depot.julia,
        env = {
            "JULIA_DEPOT_SYSIMAGE_PACKAGES": " ".join(ctx.attr.packages),
            "JULIA_DEPOT_SYSIMAGE_CPU_TARGET": _cpu_target(ctx),
            "JULIA_DEPOT_SYSIMAGE_CC": cc.env,
        },
        # Used only when the depot lacks PackageCompiler and sysimage.sh installs it.
        network = True,
        # The host's compiler is not in the key, so its result must not be shared.
        remote_cache = not ctx.attr.system_cc,
        mnemonic = "JuliaSysimage",
        message = "Building Julia sysimage %{output}",
        resource_set = _sysimage_resources,
    )

def _sysimage_attrs():
    return _tool_attrs() | _depot_attrs() | _cpu_attrs() | {
        "packages": attr.string_list(mandatory = True, doc = "Packages to bake, with everything they depend on."),
        "cpu_target": attr.string(doc = "The sysimage's CPU targets. Default: the portable list for the target platform's CPU, which costs build time and runs on any host of that architecture."),
        "data": attr.label_list(allow_files = True, doc = "Further inputs of the build outside the project, such as a file a package reads while it is compiled. Name them in `env` with $(execpath ...)."),
        "env": attr.string_dict(doc = "Variables for the build. $(execpath ...) and $(location ...) expand for `data`, and {execroot} to the absolute execution root, so `\"{execroot}/$(execpath //:config.toml)\"` is an absolute path to an input."),
        "cc": attr.label(
            default = Label("@julia_depot_cc"),
            allow_files = True,
            doc = "The C compiler that links the sysimage: a julia.cc repository such as `@my_cc`, or any executable target. Default: the module's own, zig targeting glibc 2.17.",
        ),
        "system_cc": attr.bool(doc = "Link with the host's compiler instead of `cc`. The result depends on the host, so the action is tagged no-remote-cache."),
    }

_SYSIMAGE_DOC = """
The packages come from the depot `depot` names, which its julia.depot fetch already instantiated
for this manifest. That depot is only read: a scratch depot in front takes anything the build
writes, so the action runs sandboxed. A sysimage does not replace the depot: JLLs resolve their
artifacts at startup.

The sysimage is linked by `cc`, by default the module's pinned compiler, so the compiler and the
glibc it links against are inputs of the action. `system_cc = True` uses the host's compiler
instead; the action is then tagged no-remote-cache.

The `inputs` output group holds `<name>.inputs.json`: the sysimage's declared inputs by sha256,
the same on every build of the same inputs, since the sysimage itself is not reproducible. It is
written by its own action, so `--output_groups=inputs` builds it without the sysimage.
"""

JuliaSysimageInfo = provider(
    doc = "A sysimage from julia_sysimage, for julia_sysimage_layer to ship without building it again.",
    fields = {
        "sysimage": "File: the sysimage.",
        "inputs": "File: its inputs file.",
        "host_cc": "bool: linked with the host's compiler (system_cc), so not to be cached remotely.",
        "cpu_target": "string: the CPU targets it was compiled for, the JULIA_CPU_TARGET an image starting Julia with it should set.",
    },
)

def _julia_sysimage_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".so")
    inputs = ctx.actions.declare_file(ctx.label.name + ".inputs.json")
    cc = _sysimage_cc(ctx)
    _sysimage_inputs(ctx, inputs, cc)
    _sysimage_run(ctx, out, cc)
    return [
        DefaultInfo(files = depset([out])),
        OutputGroupInfo(inputs = depset([inputs])),
        JuliaSysimageInfo(sysimage = out, inputs = inputs, host_cc = ctx.attr.system_cc, cpu_target = _cpu_target(ctx)),
    ]

julia_sysimage = rule(
    implementation = _julia_sysimage_impl,
    doc = """A PackageCompiler sysimage, `<name>.so`, to start Julia with: `julia --sysimage <file>`.
For an image, pass it to julia_sysimage_layer, which ships this build rather than repeating it.
""" + _SYSIMAGE_DOC,
    attrs = _sysimage_attrs(),
)

def _julia_sysimage_layer_impl(ctx):
    info = ctx.attr.sysimage[JuliaSysimageInfo]
    out = ctx.actions.declare_file(ctx.label.name + ".tar")

    # Only packaging, so it may run and be cached anywhere; unless the sysimage inside carries the
    # host's link, in which case the layer must not be shared either.
    reqs = {"no-remote-cache": "1"} if info.host_cc else {}
    ctx.actions.run(
        executable = ctx.executable._tool,
        arguments = ["sysimage_layer", out.path, info.sysimage.path, info.inputs.path, _check_absolute("path", ctx.attr.path)],
        inputs = [info.sysimage, info.inputs],
        outputs = [out],
        use_default_shell_env = True,
        execution_requirements = reqs,
        mnemonic = "JuliaSysimageLayer",
        progress_message = "Writing Julia sysimage layer %{output}",
    )
    return [
        DefaultInfo(files = depset([out])),
        OutputGroupInfo(inputs = depset([info.inputs])),
    ]

julia_sysimage_layer = rule(
    implementation = _julia_sysimage_layer_impl,
    doc = """A julia_sysimage as one image layer: the sysimage at `path`, its inputs file beside it.

It ships the sysimage `sysimage` built, so a build that needs the file as well as the layer
compiles it once. Ship a julia_depot_layer beside it for the artifacts, and start Julia with
`--sysimage <path>`. The `inputs` output group holds the sysimage's inputs file.
""",
    attrs = {
        "sysimage": attr.label(mandatory = True, providers = [JuliaSysimageInfo], doc = "The julia_sysimage to ship."),
        "path": attr.string(default = "/opt/julia-sysimage/sys.so", doc = "Where the image keeps the sysimage; the inputs file goes beside it as `<path without .so>.inputs.json`."),
        "_tool": attr.label(
            default = "//julia:image_layers.sh",
            allow_single_file = True,
            executable = True,
            cfg = "exec",
        ),
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
        ctx.attr.julia[DefaultInfo].files,
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
