"""The `julia` module extension: a pinned Julia distribution and Manifest-pinned depots.

    julia = use_extension("@rules_julia_depot//julia:extensions.bzl", "julia")
    julia.dist(name = "julia_dist", version = "1.12.7")
    julia.depot(
        name = "my_depot",
        manifest = "//julia:Manifest.toml",
        julia = "@julia_dist",
    )
    use_repo(julia, "julia_dist", "my_depot")

NAMING. A rule attribute that takes a repository is named after what it takes and is given
the repository itself: `julia = "@julia_dist"`, `depot = "@my_depot"`. Each repository's
default target, the one named after it, is what the rules need from it. The named targets
(`:dist`, `bin/julia`, `:env`, `env.sh`, `stamp.txt`) stay for genrules and scripts.

REPOSITORY NAMES ARE SHARED. The extension is evaluated once for the whole module graph,
so every module's `julia.dist` and `julia.depot` names land in one namespace, and two
modules declaring the same name is an error, even when the declarations are identical.
Nobody's declaration wins, because either way a module would silently build against a
Julia or a manifest it never asked for. The convention that keeps names apart: the root
module names its repositories freely, and a module that others depend on prefixes every
name it declares with its own module name (`reactant_server_julia`, not `julia_dist`).
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load(":depot.bzl", "julia_depot")

# Official Linux x86_64 (glibc) tarballs, by version, from
# https://julialang-s3.julialang.org/bin/checksums/julia-<version>.sha256. Add a row when
# you move to a version that is not here, or pass `sha256` (and `url`) on the tag for any
# version, platform or mirror.
_KNOWN_SHA256 = {
    "1.11.9": "b36363356d7a05eaf8b7b9e7a91c710f6bd3d2940be4d4e6d14b9a9f2927de35",
    "1.12.7": "4e7e9e776634d24835250de67cde39b0d4af15bc432eb20697e6be6c28ea69e8",
    "1.13.0": "8975da61c128a5e5ded3e719e868da8c8781deb7ad7913d37fb99be02a81904b",
}

_DIST_URL = "https://julialang-s3.julialang.org/bin/linux/x64/{minor}/julia-{version}-linux-x86_64.tar.gz"

# The WHOLE distribution is exposed, not just bin/julia. Julia locates its bundled
# depots (share/julia, where the stdlib JLLs live) relative to Sys.BINDIR, so a consumer
# that took only the binary would come up without a stdlib.
#
# The version header is exported for julia_depot, which reads it so that a version change
# refetches the depot. bin/julia is a small launcher that need not change between releases,
# so it cannot serve as that key.
_DIST_BUILD = """
filegroup(
    name = "dist",
    srcs = glob(["**"], exclude = ["BUILD.bazel", "WORKSPACE"]),
    visibility = ["//visibility:public"],
)

exports_files(["bin/julia", "include/julia/julia_version.h"])
"""

# The default target, so `@<name>` alone means the distribution.
_DIST_ALIAS = """
alias(
    name = "{name}",
    actual = ":dist",
    visibility = ["//visibility:public"],
)
"""

def _module_desc(mod):
    return "{} ({})".format(mod.name, "the root module" if mod.is_root else "version " + (mod.version or "unversioned"))

def _claim(names, mod, kind, name):
    """Records that `mod` declares `name`, failing clearly when another declaration has it."""
    if name in names:
        other_mod, other_kind = names[name]
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
    # it: one namespace for the whole graph. See REPOSITORY NAMES ARE SHARED above.
    names = {}
    for mod in module_ctx.modules:
        for tc in mod.tags.dist:
            _claim(names, mod, "dist", tc.name)
            sha256 = tc.sha256
            if not sha256:
                if tc.version not in _KNOWN_SHA256:
                    fail("julia.dist: no known sha256 for Julia {}; pass sha256 = ...".format(tc.version))
                sha256 = _KNOWN_SHA256[tc.version]
            minor = ".".join(tc.version.split(".")[:2])
            url = tc.url or _DIST_URL.format(minor = minor, version = tc.version)
            http_archive(
                name = tc.name,
                build_file_content = _DIST_BUILD + ("" if tc.name == "dist" else _DIST_ALIAS.format(name = tc.name)),
                sha256 = sha256,
                strip_prefix = tc.strip_prefix or ("julia-" + tc.version),
                urls = [url],
            )
        for depot in mod.tags.depot:
            _claim(names, mod, "depot", depot.name)
            julia_depot(
                name = depot.name,
                manifest = depot.manifest,
                julia = depot.julia,
                dir = depot.dir,
                hook = depot.hook,
                hook_environ = depot.hook_environ,
                timeout = depot.timeout,
            )

julia = module_extension(
    implementation = _julia_impl,
    tag_classes = {
        "dist": tag_class(
            doc = "Fetch an official Julia distribution, pinned by sha256, as a repository.",
            attrs = {
                "name": attr.string(mandatory = True, doc = "Repository name, e.g. julia_dist."),
                "version": attr.string(mandatory = True, doc = "Julia version, e.g. 1.12.7."),
                "sha256": attr.string(doc = "Tarball sha256. Optional for versions this module knows."),
                "url": attr.string(doc = "Tarball URL. Defaults to the official Linux x86_64 tarball."),
                "strip_prefix": attr.string(doc = "Defaults to julia-<version>."),
            },
        ),
        "depot": tag_class(
            doc = "Instantiate and precompile a Manifest-pinned project into the ambient depot.",
            attrs = {
                "name": attr.string(mandatory = True),
                "manifest": attr.label(mandatory = True),
                "julia": attr.label(mandatory = True, doc = "The Julia distribution, e.g. @julia_dist from julia.dist."),
                "dir": attr.string(doc = "Depot directory to instantiate into, overriding JULIA_DEPOT_PATH; {HOME} and {USER} expand from the fetch environment."),
                "hook": attr.label(doc = "Optional executable run before instantiate (private registries, credentials)."),
                "hook_environ": attr.string_list(doc = "Environment variables the hook reads; a change refetches."),
                "timeout": attr.int(default = 3600),
            },
        ),
    },
)
