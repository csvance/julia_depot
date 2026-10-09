"""A Julia environment pinned to a Manifest, as a repository rule.

Contract: the declared input is the Manifest, and the environment follows from it. It pins
every registered package by git tree hash and every JLL artifact by the tree hash in its
Artifacts.toml. Path entries are the consumer's own source, so they are srcs, not depot
content. A Manifest with no git-sourced entries therefore determines the closure, which is
what allows the depot to be treated as a keyed side effect instead of a declared output.
Check your manifest for `repo-url` entries before relying on that.

The project is the Project.toml beside the Manifest, or `project` when the lock is kept apart.
`project_srcs` are the further files a resolve reads, each workspace member's and path
package's Project.toml. All of these are copied into the repository and watched, and the rules
that build from the depot stage the copies. With `project`, the environment is instantiated from
the copies, which hold no sources, so precompiling a path package is impossible and the fetch
says so; `precompile = False` skips precompiling. instantiate.sh also fails, naming it, when a
workspace member or path package is missing from the tree. `env` adds variables to the hook's and
the instantiate's environment.

A repository rule, because fetching may use the network and `_watch` below refetches when
the Manifest changes. A genrule doing this would need no-sandbox and requires-network, and
could not declare the depot as an output.

Outputs: `env.sh`, a shell fragment consumers source before running julia, which always
exports JULIA_DEPOT_PATH; and `stamp.txt`, the resolved facts (manifest sha256, Julia
version, host triplet, depot). Julia itself is not in env.sh: consumers take it as a label
from the distribution they passed as `julia` (`@julia_dist//:bin/julia`) via $(location
...). The depot path, the only thing in env.sh, is per user.

What refetches it: the manifest, the hook and instantiate.sh, by content; the Julia version,
through the distribution's version header; the declared `dir` and `read_only_depots`, and
whether each read-only depot exists; and HOME, JULIA_PKG_SERVER, every `hook_environ`
variable and, when no `dir` is declared, JULIA_DEPOT_PATH. The contents of a read-only depot
do not; see below.

Read-only depots: a host often has a shared depot, maintained by someone else, that already
holds most of what a Manifest needs. `read_only_depots` stacks such depots after `dir`, so
the path becomes `<dir>:<ro1>:<ro2>:...:` (on Julia 1.10 the bundled depots by name in place
of the trailing separator; see _bundled_depots). Julia reads packages, artifacts and compiled
caches from every entry and writes only to the first, and Pkg installs nothing that an entry
already has, so `dir` holds only what the shared depots lack. This rule never writes to or
creates them. A missing one stays on the path, where Julia ignores it, so a host without the
shared depot fetches into `dir` alone. Whether each exists is an input, so one appearing or
disappearing refetches. Its contents are not, since watching a depot's whole tree would cost
more than the fetch it guards; a shared depot that loses something `dir` relied on needs
`bazel fetch --force @<name>`. They require `dir`. Without it the depot is the ambient
JULIA_DEPOT_PATH, which can already list any number of depots, and appending to it would
make the first entry, the one written to, depend on the shell.

The hook: an environment that resolves through a private registry or package server needs
that registry in the depot before Pkg.instantiate, and only fetch time can guarantee that.
`hook` is an executable run first, with JULIA_DEPOT_BIN set and JULIA_DEPOT_PATH set to the
value env.sh exports. `hook_environ` names the variables it reads, so a change to any of them
refetches. The hook belongs to the consumer; this module knows no particular registry. With
read-only depots the path has several entries: a hook that writes must write to the first,
as Pkg does, and may find what it would add already present in a later one.
"""

load(":dist.bzl", "host_platform")

def _env_value(rctx, name):
    # getenv registers a dependency on the variable, so a change refetches.
    return rctx.getenv(name)

def _watch(rctx, path):
    """Registers a dependency on a file, so that changing it refetches this repository.

    rctx.path() resolves a label to a path but does not watch the file, so the dependency
    is registered by reading it. watch = "auto" watches when watching that path is allowed
    and does nothing when it is not (a label into another module's directory, for example).

    Without this the repository keeps the Manifest it was first fetched with, and a changed
    Manifest reuses a depot conformed to the old one without any error. Preventing that is
    the purpose of this module.

    Args:
      rctx: the repository context.
      path: the path to watch, already resolved from a label.
    """
    rctx.read(path, watch = "auto")

def _expand_depot(rctx, template, attr = "dir"):
    """Expands {HOME} and {USER} in a depot template (`dir`, or a `read_only_depots` entry) from the fetch environment."""
    out = template
    for name in ["HOME", "USER"]:
        if ("{" + name + "}") in out:
            value = _env_value(rctx, name)
            if value == None:
                fail("julia_depot: {} = \"{}\" needs ${} but it is not set".format(attr, template, name))
            out = out.replace("{" + name + "}", value)
    if not out.startswith("/"):
        fail("julia_depot: {} must expand to an absolute path, got {}".format(attr, out))

    # The separator of JULIA_DEPOT_PATH: a depot whose path holds one would become two entries.
    if ":" in out:
        fail("julia_depot: {} must not contain ':', got {}".format(attr, out))
    return out

def _bundled_depots(rctx, julia, version_h):
    """What follows the declared depots on the path, to keep the bundled ones and no other.

    Since Julia 1.11 a trailing separator expands to the bundled depots alone. On 1.10 it
    expands to the whole default path, the user depot ~/.julia included, which would put a
    depot nobody declared behind `dir`. There the bundled depots are named instead, as Julia
    reports them: its default path after the user depot.
    """
    minor = None
    for line in rctx.read(version_h).splitlines():
        if line.startswith("#define JULIA_VERSION_MINOR "):
            minor = int(line.removeprefix("#define JULIA_VERSION_MINOR ").strip())
    if minor == None:
        fail("julia_depot: {} has no JULIA_VERSION_MINOR".format(version_h))
    if minor >= 11:
        return ":"
    res = rctx.execute(
        [str(julia), "--startup-file=no", "-e", "foreach(println, DEPOT_PATH[2:end])"],
        environment = {"JULIA_DEPOT_PATH": None},
    )
    if res.return_code != 0 or not res.stdout.strip():
        fail("julia_depot: cannot determine Julia's bundled depots:\n{}".format(res.stderr))
    return "".join([":" + d for d in res.stdout.strip().splitlines()])

def _julia_depot_impl(rctx):
    # The scripts need GNU tar and coreutils and a Linux Julia, whatever distribution is given.
    host_platform(rctx.os.name, rctx.os.arch, "julia_depot")

    # The declared inputs, copied into the repository: the Project.toml, the further files a
    # resolve reads, and the Manifest. Reading a file watches it, so an edit to any of them
    # refetches. Without `project` the environment is instantiated in place, where Pkg also
    # sees the members' sources; with it, in the copy, since the lock has no project beside it.
    files = _project_files(rctx)
    for rel, path in files.items():
        rctx.file("project/" + rel, rctx.read(path), executable = False)
    if rctx.attr.project:
        project_dir = str(rctx.path("project"))
        manifest = rctx.path("project/Manifest.toml")
    else:
        manifest = rctx.path(rctx.attr.manifest)
        project_dir = str(manifest.dirname)

    # Julia comes from a pinned distribution (julia.dist, or any repository holding an
    # official Julia tree). Taking it from PATH would make Julia depend on how the machine was
    # set up, and a juliaup launcher needs $HOME, which a fetch does not have.
    #
    # The attribute names the distribution, and the files are found beside it. The version
    # header is read so that the Julia version is a key. bin/julia is a small launcher that
    # can be identical between releases, so watching it alone would let a version bump reuse
    # a depot instantiated under the old Julia.
    julia = rctx.path(rctx.attr.julia.same_package_label("bin/julia"))
    if not julia.exists:
        fail("julia_depot: {} has no bin/julia; pass the distribution, e.g. @julia_dist".format(rctx.attr.julia))
    version_h = rctx.path(rctx.attr.julia.same_package_label("include/julia/julia_version.h"))
    if not version_h.exists:
        fail("julia_depot: {} has no include/julia/julia_version.h; is it an official Julia distribution?".format(rctx.attr.julia))
    _watch(rctx, version_h)

    # julia.dist always matches the host; a hand-declared distribution may not, and running
    # one built for another platform fails with an exec format error buried in a fetch log.
    res = rctx.execute([str(julia), "--startup-file=no", "--version"])
    if res.return_code != 0:
        fail("julia_depot: {} does not run on this host ({}/{}); declare it with julia.dist, which picks the build for the host:\n{}".format(
            rctx.attr.julia,
            rctx.os.name,
            rctx.os.arch,
            res.stderr,
        ))

    env = dict(rctx.attr.env) | {"JULIA_DEPOT_BIN": str(julia)}
    bundled = _bundled_depots(rctx, julia, version_h)

    # JULIA_DEPOT_PATH only when no `dir` is declared: a declared depot replaces it, so reading
    # it would refetch on every change to a variable that cannot change the result.
    ambient = [] if rctx.attr.dir else ["JULIA_DEPOT_PATH"]
    for name in ambient + ["JULIA_PKG_SERVER", "HOME"] + rctx.attr.hook_environ:
        value = _env_value(rctx, name)
        if value != None:
            env[name] = value

    # Julia reads an empty JULIA_DEPOT_PATH as no depots, which nothing can instantiate
    # into. Treat it as unset, so Julia's default is resolved below.
    if env.get("JULIA_DEPOT_PATH") == "":
        env.pop("JULIA_DEPOT_PATH")

    # A declared depot overrides the ambient one. The attribute is a template because a depot
    # belongs per user on a local disk and a committed file cannot carry a username: {HOME}
    # and {USER} expand from the fetch environment and register as inputs, so a different
    # user refetches. `bundled` keeps Julia's bundled depots on the path and the user depot
    # ~/.julia off it; without them Pkg is recompiled into the fresh depot, see image_depot.sh.
    # The directory is created here so a hook can write into it.
    #
    # Read-only depots go between `dir` and the separator, so `dir` stays the only entry Julia
    # and Pkg write to and the bundled depots stay last. They are not created, and a missing
    # one stays on the path, where Julia skips it. watch() registers whether each directory
    # exists (not its contents), so the depot is re-conformed when one appears or disappears.
    # See "Read-only depots" in the module docstring.
    if rctx.attr.read_only_depots and not rctx.attr.dir:
        fail("julia_depot: read_only_depots needs `dir`, the depot written to in front of them; " +
             "without it the ambient JULIA_DEPOT_PATH is used as it is, and can list them itself")
    if rctx.attr.dir:
        depot_dir = _expand_depot(rctx, rctx.attr.dir)
        stack = [depot_dir]
        for template in rctx.attr.read_only_depots:
            ro = _expand_depot(rctx, template, "read_only_depots")
            if ro in stack:
                fail("julia_depot: {} is on the depot path twice; read_only_depots must not repeat `dir` or each other".format(ro))
            stack.append(ro)
            ro_path = rctx.path(ro)
            rctx.watch(ro_path)
            if not ro_path.exists:
                # buildifier: disable=print
                print("julia_depot: read-only depot {} does not exist on this host; continuing without it".format(ro))
        env["JULIA_DEPOT_PATH"] = ":".join(stack) + bundled
        res = rctx.execute(["mkdir", "-p", depot_dir])
        if res.return_code != 0:
            fail("julia_depot: cannot create depot {}:\n{}".format(depot_dir, res.stderr))

    # Neither declared nor ambient: use Julia's default, made explicit, so the hook,
    # instantiate and every consumer of env.sh agree on one depot. Ask Julia for it instead
    # of assuming $HOME/.julia. `bundled` restores the bundled depots behind it, as in the
    # default path.
    if "JULIA_DEPOT_PATH" not in env:
        res = rctx.execute(
            [str(julia), "--startup-file=no", "-e", "print(first(DEPOT_PATH))"],
            # None removes it, so an empty value in the client environment is not inherited.
            environment = env | {"JULIA_DEPOT_PATH": None},
        )
        if res.return_code != 0 or not res.stdout:
            fail("julia_depot: cannot determine Julia's default depot:\n{}".format(res.stderr))
        env["JULIA_DEPOT_PATH"] = res.stdout + bundled

    if rctx.attr.hook != None:
        hook = rctx.path(rctx.attr.hook)
        _watch(rctx, hook)
        res = rctx.execute([str(hook)], environment = env, timeout = 600, quiet = False)
        if res.return_code != 0:
            fail("julia_depot: hook {} failed:\n{}\n{}".format(rctx.attr.hook, res.stdout, res.stderr))

    # Instantiate and precompile the depot. instantiate.sh fails if the Manifest's
    # julia_version differs from this Julia.
    script = rctx.path(rctx.attr._instantiate)
    _watch(rctx, script)
    res = rctx.execute(
        [str(script), project_dir, str(manifest), "stamp.txt", "yes" if rctx.attr.precompile else "no"],
        environment = env,
        timeout = rctx.attr.timeout,
        quiet = False,
    )
    if res.return_code != 0:
        fail("julia_depot: instantiating {} failed:\n{}\n{}".format(project_dir, res.stdout, res.stderr))

    # env.sh is the whole consumer interface: the depot the environment was instantiated
    # into, always set. That path is the only thing that varies between machines. It is
    # single-quoted, so nothing in it is expanded when the file is sourced.
    rctx.file("env.sh", """# Generated by julia_depot. Source before running julia.
# Julia itself is NOT here: take it from the distribution, @<dist>//:bin/julia.
export JULIA_DEPOT_PATH={depot}
""".format(depot = _shell_quote(env["JULIA_DEPOT_PATH"])), executable = False)

    # The default target, named after the repository, so `@<name>` alone means it: env.sh and
    # stamp.txt as files, and JuliaDepotInfo for the rules that build from the depot.
    name = rctx.original_name
    if name in ("env", "project"):
        fail("julia_depot: a depot cannot be named {}, which its own targets use".format(name))
    rctx.file("BUILD.bazel", """load("{info_bzl}", "julia_depot_info")

exports_files(["env.sh", "stamp.txt"])

filegroup(
    name = "env",
    srcs = ["env.sh", "stamp.txt"],
    visibility = ["//visibility:public"],
)

julia_depot_info(
    name = "{name}",
    env = "env.sh",
    julia = "{julia}",
    manifest = "project/Manifest.toml",
    project = "project/Project.toml",
    project_dir = "{project_dir}",
    project_srcs = {project_srcs},
    stamp = "stamp.txt",
    visibility = ["//visibility:public"],
)
""".format(
        info_bzl = str(Label("//julia:depot_info.bzl")),
        name = name,
        julia = str(rctx.attr.julia),
        project_dir = _short_dir(rctx.attr.project or rctx.attr.manifest),
        project_srcs = repr(["project/" + rel for rel in sorted(files) if rel not in ("Project.toml", "Manifest.toml")]),
    ))

def _project_files(rctx):
    """{relative path: source path} of the project tree the depot is fetched for.

    The Project.toml is `project`, or the one beside the Manifest. `project_srcs` are placed at
    their paths relative to its directory, and the Manifest is placed as Manifest.toml beside it.
    """
    manifest = rctx.attr.manifest
    project = rctx.attr.project
    if project == None:
        project = manifest.same_package_label(_join(manifest.name.rpartition("/")[0], "Project.toml"))
    project_path = rctx.path(project)
    if not project_path.exists:
        if rctx.attr.project:
            fail("julia_depot: project {} does not exist".format(project))
        fail("julia_depot: no Project.toml beside {}; if the project lives elsewhere, name it with `project`".format(manifest))
    base = _short_dir(project)
    files = {"Project.toml": project_path, "Manifest.toml": rctx.path(manifest)}
    for src in rctx.attr.project_srcs:
        short = _short_path(src)
        if base and not short.startswith(base + "/"):
            fail("julia_depot: project_srcs: {} is not under the project's directory {}".format(src, base or "(the repository root)"))
        rel = short[len(base) + 1:] if base else short
        if rel in files:
            fail("julia_depot: project_srcs: {} is the project's own {}".format(src, rel))
        files[rel] = rctx.path(src)
    return files

def _join(*parts):
    return "/".join([p for p in parts if p])

def _short_path(label):
    """A file label's path as File.short_path spells it."""
    return _join(_short_dir(label), label.name.rpartition("/")[2])

def _short_dir(label):
    """The short path of the directory a file label is in, as File.short_path spells it."""
    parts = [p for p in [label.package, label.name.rpartition("/")[0]] if p]
    if label.repo_name:
        parts = ["..", label.repo_name] + parts
    return "/".join(parts)

def _shell_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"

julia_depot = repository_rule(
    implementation = _julia_depot_impl,
    attrs = {
        "manifest": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "The Manifest.toml that pins the environment. Unless `project` is set, the " +
                  "Project.toml beside it is the project.",
        ),
        "project": attr.label(
            allow_single_file = True,
            doc = "The Project.toml the Manifest locks, when the two are not in one directory, such as " +
                  "a production lock kept apart from a development tree. The project is then staged " +
                  "inside the repository, with the Manifest beside it as Manifest.toml, and instantiated " +
                  "there; path packages have no source there, so set `precompile = False` if it has any.",
        ),
        "project_srcs": attr.label_list(
            allow_files = True,
            doc = "Further files a resolve reads, at their paths relative to the project's directory: " +
                  "the Project.toml of each workspace member and path package. Watched, so an edit " +
                  "refetches; and staged by the rules that build from the depot. Required for every " +
                  "member and path package when `project` is set.",
        ),
        "precompile": attr.bool(
            default = True,
            doc = "Precompile the environment after instantiating it. False for a depot only images " +
                  "are built from, whose caches come from julia_compiled_layer.",
        ),
        "env": attr.string_dict(
            doc = "Variables for the hook and the instantiate, such as what a package's platform " +
                  "augmentation reads to select an artifact. The rule's own JULIA_DEPOT_* win.",
        ),
        "julia": attr.label(
            mandatory = True,
            doc = "The Julia distribution to instantiate with, e.g. @julia_dist from julia.dist. Any " +
                  "target in the distribution's root package works: bin/julia and the version header " +
                  "are found beside it.",
        ),
        "dir": attr.string(
            doc = "The depot directory to instantiate into, overriding JULIA_DEPOT_PATH. {HOME} and " +
                  "{USER} expand from the fetch environment. Exported through env.sh with Julia's bundled " +
                  "depots behind it: a trailing separator, or on Julia 1.10 their paths.",
        ),
        "read_only_depots": attr.string_list(
            doc = "Depots searched after `dir` and never written to, such as a host's shared depot: " +
                  "what they already hold is not installed into `dir`. Templates like `dir`; requires " +
                  "`dir`. A missing one is skipped. Their contents are not watched.",
        ),
        "hook": attr.label(
            allow_single_file = True,
            doc = "Optional executable run before instantiate, with JULIA_DEPOT_BIN and JULIA_DEPOT_PATH set.",
        ),
        "hook_environ": attr.string_list(
            doc = "Environment variables the hook reads. Each is passed through and a change refetches.",
        ),
        "timeout": attr.int(
            default = 3600,
            doc = "Seconds. A cold instantiate of a large environment takes minutes.",
        ),
        "_instantiate": attr.label(
            default = "//julia:instantiate.sh",
            allow_single_file = True,
        ),
    },
    doc = "Instantiates and precompiles a Julia project into the declared or ambient depot, failing on a Julia version mismatch.",
)
