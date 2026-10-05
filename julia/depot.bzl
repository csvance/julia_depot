"""A Julia environment pinned to a Manifest, as a repository rule.

THE CONTRACT. The declared input is Manifest.toml. Everything about the environment
follows from it: every registered package by git tree hash, every JLL artifact by tree
hash from its Artifacts.toml, and path entries that are the consumer's own source and
therefore srcs rather than depot content. A Manifest with no git-sourced entries
therefore determines the closure, which is what makes it legitimate to treat the depot
as a keyed side effect rather than a declared output. Check your manifest for
`repo-url` entries before relying on that.

A REPOSITORY RULE, not a genrule, for two reasons. Fetch time is where hitting the
network is legitimate, and a repository rule can be made to refetch when the Manifest
changes, which is what `_watch` below is for. A build-time genrule doing the same work
would need no-sandbox plus requires-network and would be lying to Bazel about its
inputs.

WHAT IT PRODUCES. `env.sh`, a shell fragment consumers source before running julia,
which always exports JULIA_DEPOT_PATH, and `stamp.txt`, the resolved facts (manifest
sha256, Julia version, host triplet, depot). Julia itself is not in env.sh: consumers
take it as a label from the distribution they passed as `julia` (`@julia_dist//:bin/julia`)
via $(location ...). The depot is the one path in env.sh, and it is per user by nature.

WHAT REFETCHES IT. The manifest, the hook and instantiate.sh, by content; the Julia
version, through the distribution's version header; the declared `dir`; and HOME,
JULIA_DEPOT_PATH, JULIA_PKG_SERVER and every `hook_environ` variable.

THE HOOK. Environments that resolve through a private registry or package server need
that registry in the depot BEFORE Pkg.instantiate, and fetch time is the only place
that can guarantee it. `hook` is an executable run first, with RULES_JULIA_DEPOT_BIN and
JULIA_DEPOT_PATH set, the latter to the same value env.sh exports; `hook_environ` names the variables it reads, so a change to any
of them refetches. The hook is the consumer's: this module knows nothing about any
particular registry.
"""

load(":dist.bzl", "host_platform")

def _env_value(rctx, name):
    # getenv registers a dependency on the variable, so a change refetches.
    return rctx.getenv(name)

def _watch(rctx, path):
    """Registers a dependency on a file, so that changing it refetches this repository.

    rctx.path() resolves a label to a path and does NOTHING ELSE: it does not watch the
    file. Registering the dependency has to be explicit, and reading the file is how it
    is done, since watch = "auto" watches when watching that path is legal and stays
    quiet when it is not (a label pointing into another module's directory, say).

    Without this the repository stays pinned to whatever the Manifest said the first time
    it was fetched, and a changed Manifest silently reuses a depot conformed to the old
    one, which is the exact failure this module exists to prevent.

    Args:
      rctx: the repository context.
      path: the path to watch, already resolved from a label.
    """
    rctx.read(path, watch = "auto")

def _expand_depot(rctx, template):
    """Expands {HOME} and {USER} in a depot template from the fetch environment."""
    out = template
    for name in ["HOME", "USER"]:
        if ("{" + name + "}") in out:
            value = _env_value(rctx, name)
            if value == None:
                fail("julia_depot: depot template {} needs ${} but it is not set".format(template, name))
            out = out.replace("{" + name + "}", value)
    if not out.startswith("/"):
        fail("julia_depot: depot must expand to an absolute path, got {}".format(out))
    return out

def _julia_depot_impl(rctx):
    # The scripts need GNU tar and coreutils and a Linux Julia, whatever distribution is given.
    host_platform(rctx.os.name, rctx.os.arch, "julia_depot")

    # The declared input. Change the Manifest, Bazel refetches: see _watch.
    manifest = rctx.path(rctx.attr.manifest)
    _watch(rctx, manifest)
    project_dir = str(manifest.dirname)

    # Julia comes from a pinned distribution (julia.dist, or any repository holding an
    # official Julia tree), NOT from PATH. PATH made Julia a property of whoever set the
    # machine up, and a juliaup launcher needs $HOME, which a fetch has none of.
    #
    # The attribute names the distribution, and the files are found beside it. The
    # version header is READ, so the Julia version is a key: bin/julia is a small
    # launcher that can be identical between releases, so watching it alone would let a
    # version bump reuse a depot instantiated under the old Julia.
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

    env = {"RULES_JULIA_DEPOT_BIN": str(julia)}
    for name in ["JULIA_DEPOT_PATH", "JULIA_PKG_SERVER", "HOME"] + rctx.attr.hook_environ:
        value = _env_value(rctx, name)
        if value != None:
            env[name] = value

    # Julia reads an empty JULIA_DEPOT_PATH as NO depots, which nothing can instantiate
    # into. Treat it as unset, so Julia's default is resolved below instead.
    if env.get("JULIA_DEPOT_PATH") == "":
        env.pop("JULIA_DEPOT_PATH")

    # A declared depot beats the ambient one. The attribute is a template, because the
    # right place for a depot is per user on a local disk and a committed file cannot
    # carry a username: {HOME} and {USER} expand from the fetch environment (and register
    # as inputs, so a different user refetches). The trailing separator keeps Julia's
    # bundled depots on the path, and (since Julia 1.10) leaves the user depot ~/.julia
    # OFF it; without the separator Pkg is recompiled into the fresh depot, see
    # instantiate.sh. The directory is created here so a hook can write into it.
    if rctx.attr.dir:
        depot_dir = _expand_depot(rctx, rctx.attr.dir)
        env["JULIA_DEPOT_PATH"] = depot_dir + ":"
        res = rctx.execute(["mkdir", "-p", depot_dir])
        if res.return_code != 0:
            fail("julia_depot: cannot create depot {}:\n{}".format(depot_dir, res.stderr))

    # Neither declared nor ambient: Julia's own default, made explicit, so the hook,
    # instantiate and every consumer of env.sh agree on one depot. Julia is asked rather
    # than $HOME/.julia assumed, because that is what Julia would do. The trailing
    # separator restores the bundled depots behind it, exactly as the default has them.
    if "JULIA_DEPOT_PATH" not in env:
        res = rctx.execute(
            [str(julia), "--startup-file=no", "-e", "print(first(DEPOT_PATH))"],
            # None removes it, so an empty value in the client environment is not inherited.
            environment = env | {"JULIA_DEPOT_PATH": None},
        )
        if res.return_code != 0 or not res.stdout:
            fail("julia_depot: cannot determine Julia's default depot:\n{}".format(res.stderr))
        env["JULIA_DEPOT_PATH"] = res.stdout + ":"

    if rctx.attr.hook != None:
        hook = rctx.path(rctx.attr.hook)
        _watch(rctx, hook)
        res = rctx.execute([str(hook)], environment = env, timeout = 600, quiet = False)
        if res.return_code != 0:
            fail("julia_depot: hook {} failed:\n{}\n{}".format(rctx.attr.hook, res.stdout, res.stderr))

    # Materialise the depot: instantiate and precompile, failing loudly if the
    # Manifest's julia_version disagrees with this Julia.
    script = rctx.path(rctx.attr._instantiate)
    _watch(rctx, script)
    res = rctx.execute(
        [str(script), project_dir, str(manifest), "stamp.txt"],
        environment = env,
        timeout = rctx.attr.timeout,
        quiet = False,
    )
    if res.return_code != 0:
        fail("julia_depot: instantiating {} failed:\n{}\n{}".format(project_dir, res.stdout, res.stderr))

    # env.sh is the whole consumer interface: the depot the environment was instantiated
    # into, always set. The path is genuinely environmental and therefore the one thing
    # that legitimately varies between machines. Single-quoted, so nothing in the path
    # is expanded when the file is sourced.
    rctx.file("env.sh", """# Generated by julia_depot. Source before running julia.
# Julia itself is NOT here: take it from the distribution, @<dist>//:bin/julia.
export JULIA_DEPOT_PATH={depot}
""".format(depot = _shell_quote(env["JULIA_DEPOT_PATH"])), executable = False)

    # The default target, named after the repository, so `@<name>` alone means it.
    name = rctx.original_name
    rctx.file("BUILD.bazel", """exports_files(["env.sh", "stamp.txt"])

filegroup(
    name = "env",
    srcs = ["env.sh", "stamp.txt"],
    visibility = ["//visibility:public"],
)
""" + ("" if name == "env" else """
alias(
    name = "{name}",
    actual = ":env",
    visibility = ["//visibility:public"],
)
""".format(name = name)))

def _shell_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"

julia_depot = repository_rule(
    implementation = _julia_depot_impl,
    attrs = {
        "manifest": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "The Manifest.toml that pins the environment. Its directory is the project.",
        ),
        "julia": attr.label(
            mandatory = True,
            doc = "The Julia distribution to instantiate with, e.g. @julia_dist from julia.dist. Any " +
                  "target in the distribution's root package works; bin/julia and the version header " +
                  "are found beside it.",
        ),
        "dir": attr.string(
            doc = "The depot directory to instantiate into, overriding JULIA_DEPOT_PATH. {HOME} and " +
                  "{USER} expand from the fetch environment. Exported through env.sh with a trailing " +
                  "separator so Julia's bundled depots stay on the path.",
        ),
        "hook": attr.label(
            allow_single_file = True,
            doc = "Optional executable run before instantiate, with RULES_JULIA_DEPOT_BIN and JULIA_DEPOT_PATH set.",
        ),
        "hook_environ": attr.string_list(
            doc = "Environment variables the hook reads. Each is passed through and a change refetches.",
        ),
        "timeout": attr.int(
            default = 3600,
            doc = "Seconds. A cold instantiate of a large environment is minutes, not seconds.",
        ),
        "_instantiate": attr.label(
            default = "//julia:instantiate.sh",
            allow_single_file = True,
        ),
    },
    doc = "Instantiates and precompiles a Julia project into the ambient depot, failing loudly on a version mismatch.",
)
