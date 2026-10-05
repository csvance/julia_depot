"""An official Julia distribution for the host, pinned by sha256, as a repository rule.

THE HOST DECIDES THE BUILD. The platform is detected when the repository is fetched, not
when the extension is evaluated, so a host that cannot run Julia here only fails when a
Julia target is actually needed, and the extension's result in MODULE.bazel.lock stays the
same on every host.

    Linux x86_64    linux-x86_64     https://julialang-s3.julialang.org/bin/linux/x64/...
    Linux aarch64   linux-aarch64    https://julialang-s3.julialang.org/bin/linux/aarch64/...

Linux x86_64 is the supported platform. Linux aarch64 is mapped too, but untested and not
supported: it may work. macOS and Windows are refused, as is any other architecture: the
module's scripts need GNU tar, coreutils and a Linux layout, so a distribution that
downloaded would still fail later.

`url` and `strip_prefix` are templates, so one declaration serves every supported platform,
a mirror included: {version} (1.12.7), {minor} (1.12), {platform} (linux-x86_64) and
{arch_dir} (x64, the directory julialang-s3 files the build under).
"""

# Official tarballs, by version and platform, from
# https://julialang-s3.julialang.org/bin/checksums/julia-<version>.sha256. Add a version
# here, or pass `sha256 = {"<platform>": ...}` on the tag for any version or mirror.
_KNOWN_SHA256 = {
    "1.11.9": {
        "linux-aarch64": "a2071f0654d1d6af4381cba650b9f790f5f8bb7a570e51e378de8bcf67ff623e",
        "linux-x86_64": "b36363356d7a05eaf8b7b9e7a91c710f6bd3d2940be4d4e6d14b9a9f2927de35",
    },
    "1.12.7": {
        "linux-aarch64": "9243c0b524c7f300883240a1ee5ea3916a30e070bff718acf8ccaee31a731ef2",
        "linux-x86_64": "4e7e9e776634d24835250de67cde39b0d4af15bc432eb20697e6be6c28ea69e8",
    },
    "1.13.0": {
        "linux-aarch64": "6cd4a3e4baa2dc5f55638c28e9835fc294f41c78ada4a740dc408436778ab8b4",
        "linux-x86_64": "8975da61c128a5e5ded3e719e868da8c8781deb7ad7913d37fb99be02a81904b",
    },
}

DEFAULT_URL = "https://julialang-s3.julialang.org/bin/linux/{arch_dir}/{minor}/julia-{version}-{platform}.tar.gz"
DEFAULT_STRIP_PREFIX = "julia-{version}"

# Bazel's spelling of the host CPU, which follows the JVM's os.arch, to Julia's.
_ARCHES = {
    "amd64": ("x86_64", "x64"),
    "x86_64": ("x86_64", "x64"),
    "aarch64": ("aarch64", "aarch64"),
    "arm64": ("aarch64", "aarch64"),
}

def host_platform(os_name, arch, what = "julia.dist"):
    """Maps a host to the Julia build for it: (platform, arch_dir), or fails clearly.

    Args:
      os_name: repository_ctx.os.name.
      arch: repository_ctx.os.arch.
      what: the rule or tag to name in the error.

    Returns:
      A tuple of the platform string (linux-x86_64) and the julialang-s3 directory (x64).
    """
    name = os_name.lower()
    if name.startswith("mac") or "darwin" in name:
        fail("{}: macOS is not supported yet; rules_julia_depot supports Linux x86_64".format(what))
    if name.startswith("windows"):
        fail("{}: Windows is not supported yet; rules_julia_depot supports Linux x86_64".format(what))
    if not name.startswith("linux"):
        fail("{}: {} is not supported; rules_julia_depot supports Linux x86_64".format(what, os_name))
    if arch not in _ARCHES:
        fail("{}: Linux on {} is not supported yet; rules_julia_depot supports Linux x86_64".format(what, arch))
    julia_arch, arch_dir = _ARCHES[arch]
    return "linux-" + julia_arch, arch_dir

# The WHOLE distribution is exposed, not just bin/julia. Julia locates its bundled
# depots (share/julia, where the stdlib JLLs live) relative to Sys.BINDIR, so a consumer
# that took only the binary would come up without a stdlib.
#
# The version header is exported for julia_depot, which reads it so that a version change
# refetches the depot. bin/julia is a small launcher that need not change between releases,
# so it cannot serve as that key.
_BUILD = """
filegroup(
    name = "dist",
    srcs = glob(["**"], exclude = ["BUILD.bazel", "WORKSPACE", "REPO.bazel"]),
    visibility = ["//visibility:public"],
)

exports_files(["bin/julia", "include/julia/julia_version.h"])
"""

# The default target, so `@<name>` alone means the distribution.
_ALIAS = """
alias(
    name = "{name}",
    actual = ":dist",
    visibility = ["//visibility:public"],
)
"""

def _julia_dist_impl(rctx):
    platform, arch_dir = host_platform(rctx.os.name, rctx.os.arch)
    version = rctx.attr.version
    subs = {
        "{arch_dir}": arch_dir,
        "{minor}": ".".join(version.split(".")[:2]),
        "{platform}": platform,
        "{version}": version,
    }

    sha256 = rctx.attr.sha256.get(platform) or _KNOWN_SHA256.get(version, {}).get(platform)
    if not sha256:
        fail(("julia.dist: no known sha256 for Julia {} on {}; pass sha256 = {{\"{}\": ...}} from " +
              "https://julialang-s3.julialang.org/bin/checksums/julia-{}.sha256").format(version, platform, platform, version))

    rctx.download_and_extract(
        url = _expand(rctx.attr.url, subs),
        sha256 = sha256,
        strip_prefix = _expand(rctx.attr.strip_prefix, subs),
    )
    name = rctx.original_name
    rctx.file("BUILD.bazel", _BUILD + ("" if name == "dist" else _ALIAS.format(name = name)))

def _expand(template, subs):
    out = template
    for k, v in subs.items():
        out = out.replace(k, v)
    return out

julia_dist = repository_rule(
    implementation = _julia_dist_impl,
    attrs = {
        "version": attr.string(mandatory = True, doc = "Julia version, e.g. 1.12.7."),
        "sha256": attr.string_dict(doc = "Tarball sha256 by platform (linux-x86_64, linux-aarch64). Optional for versions this module knows."),
        "url": attr.string(default = DEFAULT_URL, doc = "Tarball URL template; {version}, {minor}, {platform} and {arch_dir} expand."),
        "strip_prefix": attr.string(default = DEFAULT_STRIP_PREFIX, doc = "Archive prefix template, expanded like `url`."),
    },
    doc = "Downloads the official Julia distribution for the host platform, pinned by sha256.",
)
