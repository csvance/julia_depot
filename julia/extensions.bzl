"""The `julia` module extension: a pinned Julia distribution and Manifest-pinned depots.

    julia = use_extension("@julia_depot//julia:extensions.bzl", "julia")
    julia.dist(name = "julia_dist", version = "1.12.7")
    julia.depot(
        name = "my_depot",
        manifest = "//julia:Manifest.toml",
        julia = "@julia_dist",
    )
    use_repo(julia, "julia_dist", "my_depot")

Naming: a rule attribute that takes a repository is named after what it takes and is given
the repository itself: `julia = "@julia_dist"`, `depot = "@my_depot"`. The rules use each
repository's default target, the one named after it. The named targets (`:dist`,
`bin/julia`, `:env`, `env.sh`, `stamp.txt`) remain for genrules and scripts.

Repository names are shared: the extension is evaluated once for the whole module graph, so
every module's `julia.dist` and `julia.depot` names share one namespace. Two modules
declaring the same name is an error, even when the declarations are identical, because
letting either win would make the other module build against a Julia or a manifest it did
not declare. To keep names apart, the root module names its repositories freely, and a
module that others depend on prefixes every name with its own module name (for example
`reactant_server_julia` for its `julia_dist`).
"""

load(":depot.bzl", "julia_depot")
load(":dist.bzl", "DEFAULT_STRIP_PREFIX", "DEFAULT_URL", "julia_dist")

def _module_desc(mod):
    if mod.is_root:
        return "{} (the root module)".format(mod.name) if mod.name else "the root module"
    return "{} (version {})".format(mod.name, mod.version or "unversioned")

def _claim(names, mod, kind, name):
    """Records that `mod` declares `name`, failing when another declaration already has it."""
    if name in names:
        other_mod, other_kind = names[name]
        if other_mod.name == mod.name:
            fail("""julia.{kind}(name = "{name}") in {mod} reuses a name it already gave to a julia.{other_kind}.

Each repository from the `julia` extension needs its own name; rename one of the two.""".format(
                kind = kind,
                name = name,
                mod = _module_desc(mod),
                other_kind = other_kind,
            ))
        fail("""julia.{kind}(name = "{name}") in {mod} clashes with julia.{other_kind}(name = "{name}") in {other}.

Repository names from the `julia` extension are shared by every module in the graph, so each
name can be declared once. Rename one of them: a module that others depend on prefixes its
names with its own module name (for example "{prefix}_{name}"), and the root module keeps the
plain ones. Neither declaration can win, since the other module would then build against a
Julia or a manifest it never declared.""".format(
            kind = kind,
            name = name,
            mod = _module_desc(mod),
            other_kind = other_kind,
            other = _module_desc(other_mod),
            prefix = (other_mod if mod.is_root else mod).name,
        ))
    names[name] = (mod, kind)

def _julia_impl(module_ctx):
    # Every repository this extension creates, by name, with the module and tag that declared
    # it: one namespace for the whole graph. See "Repository names are shared" above.
    names = {}
    for mod in module_ctx.modules:
        for tc in mod.tags.dist:
            _claim(names, mod, "dist", tc.name)
            julia_dist(
                name = tc.name,
                version = tc.version,
                sha256 = tc.sha256,
                url = tc.url,
                strip_prefix = tc.strip_prefix,
            )
        for depot in mod.tags.depot:
            _claim(names, mod, "depot", depot.name)
            julia_depot(
                name = depot.name,
                manifest = depot.manifest,
                julia = depot.julia,
                dir = depot.dir,
                read_only_depots = depot.read_only_depots,
                hook = depot.hook,
                hook_environ = depot.hook_environ,
                timeout = depot.timeout,
            )

julia = module_extension(
    implementation = _julia_impl,
    tag_classes = {
        "dist": tag_class(
            doc = "Fetch the official Julia distribution for the host, pinned by sha256. Linux x86_64 is supported; aarch64 is mapped but untested.",
            attrs = {
                "name": attr.string(mandatory = True, doc = "Repository name, e.g. julia_dist."),
                "version": attr.string(mandatory = True, doc = "Julia version, e.g. 1.12.7."),
                "sha256": attr.string_dict(doc = "Tarball sha256 by platform (linux-x86_64, linux-aarch64). Optional for versions this module knows."),
                "url": attr.string(default = DEFAULT_URL, doc = "Tarball URL template; {version}, {minor}, {platform} and {arch_dir} expand. Defaults to julialang-s3."),
                "strip_prefix": attr.string(default = DEFAULT_STRIP_PREFIX, doc = "Archive prefix template, expanded like `url`."),
            },
        ),
        "depot": tag_class(
            doc = "Instantiate and precompile a Manifest-pinned project into the declared (`dir`) or ambient depot.",
            attrs = {
                "name": attr.string(mandatory = True),
                "manifest": attr.label(mandatory = True),
                "julia": attr.label(mandatory = True, doc = "The Julia distribution, e.g. @julia_dist from julia.dist."),
                "dir": attr.string(doc = "Depot directory to instantiate into, overriding JULIA_DEPOT_PATH; {HOME} and {USER} expand from the fetch environment."),
                "read_only_depots": attr.string_list(doc = "Depots searched after `dir` and never written to, such as a host's shared depot, so `dir` holds only what they lack. Templates like `dir`; requires `dir`; a missing one is skipped, and their contents are not watched."),
                "hook": attr.label(doc = "Optional executable run before instantiate (private registries, credentials)."),
                "hook_environ": attr.string_list(doc = "Environment variables the hook reads; a change refetches."),
                "timeout": attr.int(default = 3600),
            },
        ),
    },
)
