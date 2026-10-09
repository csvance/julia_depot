"""The end-to-end test matrix, as one macro per axis.

`julia_version_tests` declares every test of a single Julia version and is called once
per version in the matrix. `version_mismatch_test` is the one case that needs two versions,
and is called once per ordered pair.

Every test is tagged `julia<minor>` for the Julia it runs, so CI can shard the matrix across
runners. A cross-version test runs one Julia against the other's Manifest, which is a source
file, not a fetched repository, so the test belongs to one shard. Tagging it for both would
make each runner instantiate both versions to test one.
"""

load("@rules_shell//shell:sh_test.bzl", "sh_test")

# Test actions do not inherit the developer's shell environment, so with this pin they
# resolve against the public package server on a workstation and on a CI runner alike.
# The matching pin for repository rules is in .bazelrc.
_TEST_ENV = {"JULIA_PKG_SERVER": "https://pkg.julialang.org"}

_HELPERS = ["common.sh"]

def _tag(minor):
    return minor.replace(".", "_")

def julia_version_tests(
        minor,
        patch,
        julia_repo,
        depot_repo,
        project,
        other_minor,
        sysimage_depot_repo = None,
        hook_depot_repo = None):
    """Declares every single-version end-to-end test for one Julia version.

    Args:
      minor: the Julia minor, e.g. "1.12". Names the targets and the tag.
      patch: the full version the distribution pins, e.g. "1.12.7".
      julia_repo: the distribution repository, e.g. "@julia_1_12".
      depot_repo: the depot over projects/v<minor>, e.g. "@depot_1_12".
      project: the project package, e.g. "//projects/v1.12".
      other_minor: a different minor, for the sysimage pin check.
      sysimage_depot_repo: the depot over the module's PackageCompiler environment. None for
        a minor the module ships no environment for, which skips its check.
      hook_depot_repo: the depot whose fetch runs hooks/marker_hook.sh. None skips the hook
        test; it is version-independent, so a version run with the reduced set omits it.
    """
    tag = _tag(minor)
    tags = ["julia" + tag]

    sh_test(
        name = "dist_version_{}_test".format(tag),
        size = "small",
        srcs = ["dist_version_test.sh"],
        args = [
            "$(rootpath {}//:bin/julia)".format(julia_repo),
            patch,
        ],
        data = _HELPERS + [
            julia_repo + "//:bin/julia",
            julia_repo + "//:dist",
        ],
        env = _TEST_ENV,
        tags = tags,
    )

    sh_test(
        name = "depot_stamp_{}_test".format(tag),
        size = "small",
        srcs = ["depot_stamp_test.sh"],
        args = [
            "$(rootpath {}//:env.sh)".format(depot_repo),
            "$(rootpath {}//:stamp.txt)".format(depot_repo),
            "$(rootpath {}:Manifest.toml)".format(project),
            patch,
        ],
        data = _HELPERS + [
            depot_repo + "//:env.sh",
            depot_repo + "//:stamp.txt",
            project + ":Manifest.toml",
        ],
        env = _TEST_ENV,
        tags = tags,
    )

    # The hook is version-independent, so not every version declares a hook depot.
    if hook_depot_repo:
        sh_test(
            name = "hook_{}_test".format(tag),
            size = "small",
            srcs = ["hook_test.sh"],
            args = [
                "$(rootpath {}//:stamp.txt)".format(hook_depot_repo),
                "$(rootpath {}//:env.sh)".format(hook_depot_repo),
                "julia-depot-e2e-hook",
            ],
            data = _HELPERS + [
                hook_depot_repo + "//:env.sh",
                hook_depot_repo + "//:stamp.txt",
            ],
            env = _TEST_ENV,
            tags = tags,
        )

    sh_test(
        name = "image_depot_modes_{}_test".format(tag),
        size = "large",
        srcs = ["image_depot_modes_test.sh"],
        args = [
            "$(rootpath @julia_depot//julia:image_depot.sh)",
            "$(rootpath {}//:bin/julia)".format(julia_repo),
            "$(rootpath {}:Manifest.toml)".format(project),
            "$(rootpath {}//:stamp.txt)".format(depot_repo),
        ],
        data = _HELPERS + [
            "@julia_depot//julia:image_depot.sh",
            depot_repo + "//:stamp.txt",
            julia_repo + "//:bin/julia",
            julia_repo + "//:dist",
            project + ":Manifest.toml",
            project + ":Project.toml",
        ],
        env = _TEST_ENV,
        tags = tags + ["requires-network"],
    )

    sh_test(
        name = "image_depot_overrides_{}_test".format(tag),
        size = "large",
        srcs = ["image_depot_overrides_test.sh"],
        args = [
            "$(rootpath @julia_depot//julia:image_depot.sh)",
            "$(rootpath @julia_depot//julia:artifact_paths.jl)",
            "$(rootpath {}//:bin/julia)".format(julia_repo),
            "$(rootpath {}:Manifest.toml)".format(project),
            "$(rootpath {}//:stamp.txt)".format(depot_repo),
        ],
        data = _HELPERS + [
            "@julia_depot//julia:artifact_paths.jl",
            "@julia_depot//julia:image_depot.sh",
            depot_repo + "//:stamp.txt",
            julia_repo + "//:bin/julia",
            julia_repo + "//:dist",
            project + ":Manifest.toml",
            project + ":Project.toml",
        ],
        env = _TEST_ENV,
        tags = tags + ["requires-network"],
    )

    # The module's PackageCompiler environment for this minor instantiates under this Julia, into
    # the version's own depot beside the project, where the sysimage rules find it already
    # installed. Declared only where the module ships an environment for this minor.
    if sysimage_depot_repo:
        sh_test(
            name = "sysimage_depot_stamp_{}_test".format(tag),
            size = "small",
            srcs = ["depot_stamp_test.sh"],
            args = [
                "$(rootpath {}//:env.sh)".format(sysimage_depot_repo),
                "$(rootpath {}//:stamp.txt)".format(sysimage_depot_repo),
                "$(rootpath @julia_depot//julia:sysimage/v{}/Manifest.toml)".format(minor),
                patch,
                "/.julia-depot-e2e/v{}:".format(minor),
            ],
            data = _HELPERS + [
                "@julia_depot//julia:sysimage/v{}/Manifest.toml".format(minor),
                sysimage_depot_repo + "//:env.sh",
                sysimage_depot_repo + "//:stamp.txt",
            ],
            env = _TEST_ENV,
            tags = tags,
        )

    sh_test(
        name = "sysimage_wrong_minor_{}_test".format(tag),
        size = "small",
        srcs = ["sysimage_wrong_minor_test.sh"],
        args = [
            "$(rootpath @julia_depot//julia:sysimage.sh)",
            "$(rootpath {}//:bin/julia)".format(julia_repo),
            "$(rootpath @julia_depot//julia:sysimage/v{}/Manifest.toml)".format(other_minor),
            "$(rootpath {}:Manifest.toml)".format(project),
            other_minor,
            minor,
        ],
        data = _HELPERS + [
            "@julia_depot//julia:sysimage.sh",
            "@julia_depot//julia:sysimage/v{}/Manifest.toml".format(other_minor),
            "@julia_depot//julia:sysimage_envs",
            julia_repo + "//:bin/julia",
            julia_repo + "//:dist",
            project + ":Manifest.toml",
            project + ":Project.toml",
        ],
        env = _TEST_ENV,
        tags = tags,
    )

def version_mismatch_test(julia_repo, running_minor, running_patch, depot_repo, project, manifest_minor, manifest_patch):
    """Declares the version mismatch test for one (running Julia, foreign Manifest) pair.

    Args:
      julia_repo: the distribution that runs, e.g. "@julia_1_12".
      running_minor: its minor, for the target name.
      running_patch: its full version, which the error message must name.
      depot_repo: a depot instantiated under the running Julia, used only as a read
        cache so the test does not precompile Pkg from nothing.
      project: the project whose Manifest was resolved under the other Julia, e.g.
        "//projects/v1.13".
      manifest_minor: that Manifest's minor, for the target name.
      manifest_patch: that Manifest's julia_version, which the error message must name.
    """
    sh_test(
        name = "version_mismatch_{}_manifest_on_{}_test".format(_tag(manifest_minor), _tag(running_minor)),
        # Medium: on a cold CI runner a fresh depot pays Pkg's first-load cost before the
        # version check runs, and that alone exceeded the 60 s limit of small.
        size = "medium",
        srcs = ["version_mismatch_test.sh"],
        args = [
            "$(rootpath @julia_depot//julia:instantiate.sh)",
            "$(rootpath {}//:bin/julia)".format(julia_repo),
            "$(rootpath {}:Manifest.toml)".format(project),
            "$(rootpath {}//:stamp.txt)".format(depot_repo),
            manifest_patch,
            running_patch,
        ],
        data = _HELPERS + [
            "@julia_depot//julia:instantiate.sh",
            depot_repo + "//:stamp.txt",
            julia_repo + "//:bin/julia",
            julia_repo + "//:dist",
            project + ":Manifest.toml",
            project + ":Project.toml",
        ],
        env = _TEST_ENV,
        tags = ["julia" + _tag(running_minor)],
    )
