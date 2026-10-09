"""The image example and its tests, for one Julia version.

`julia_image_tests` builds, for one version in the matrix, what a consumer of julia/image.bzl
builds: the distribution, depot, compiled and application layers, the image environment, and an
oci_image assembled from them with rules_oci. The tests check that the layers hold what they
should and are normalised, that two independent builds of a layer are byte-identical, that the
image starts without precompiling (and that the check fails when it would precompile), that a
sysimage layer does the same without any caches, and that the environment and layers reach the
image's config.

Every test is tagged `julia<minor>`, like tests/defs.bzl, so a CI shard runs one version.
"""

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
load("@rules_oci//oci:defs.bzl", "oci_image")
load("@rules_shell//shell:sh_test.bzl", "sh_test")

_HELPERS = ["//tests:common.sh"]

# The application's project in the image: only a Project.toml and its Manifest.toml. The e2e
# project is an environment, not a package, so all its code is in the depot.
_APP = "/opt/app"

# The application layer: what a consumer ships of its own, here the project files. Written with
# the same tar flags as the module's layers, which any reproducible layer needs. A consumer would
# more likely use rules_oci's ecosystem (aspect_bazel_lib's `tar`).
_APP_LAYER_CMD = """
set -euo pipefail
stage="$$(mktemp -d)"
trap 'rm -rf "$$stage"' EXIT
mkdir -p "$$stage{app}"
cp -L $(location {project}:Project.toml) $(location {project}:Manifest.toml) "$$stage{app}/"
LC_ALL=C tar --create --file "$@" --format=gnu --sort=name --mtime=@0 \\
    --owner=0 --group=0 --numeric-owner --mode='u=rwX,go=rX' --directory "$$stage" opt
"""

# Named by `minor`, like the macros in tests/defs.bzl. buildifier asks for `name` because of the
# genrule.
# buildifier: disable=unnamed-macro
def julia_image_tests(minor, julia_repo, depot_repo, project):
    """Declares the image example and its tests for one Julia version.

    Args:
      minor: the Julia minor, e.g. "1.12". Names the targets and the tag.
      julia_repo: the distribution repository, e.g. "@julia_1_12".
      depot_repo: the depot over `project`, e.g. "@depot_1_12".
      project: the project package, e.g. "//projects/v1.12".
    """
    tag = minor.replace(".", "_")
    tags = ["julia" + tag]
    julia = julia_repo

    def n(what):
        return "{}_{}".format(what, tag)

    # --- the image ------------------------------------------------------------------------
    julia_image_env(
        name = n("image_env"),
        project = _APP,
    )

    julia_dist_layer(
        name = n("dist_layer"),
        julia = julia,
    )

    # `full`, because the image loads its packages from source with the compiled layer's caches.
    # `depot` reuses the version's depot's registry instead of fetching it again.
    julia_depot_layer(
        name = n("depot_layer"),
        contents = "full",
        depot = depot_repo,
        julia = julia,
        manifest = project + ":Manifest.toml",
        project = project + ":Project.toml",
    )

    native.genrule(
        name = n("app_layer"),
        srcs = [
            project + ":Manifest.toml",
            project + ":Project.toml",
        ],
        outs = [n("app_layer") + ".tar"],
        cmd = _APP_LAYER_CMD.format(app = _APP, project = project),
    )

    julia_compiled_layer(
        name = n("compiled_layer"),
        image_env = n("image_env"),
        julia = julia,
        layers = [
            n("dist_layer"),
            n("depot_layer"),
            n("app_layer"),
        ],
        projects = [_APP],
    )

    oci_image(
        name = n("image"),
        base = "@debian_base",
        entrypoint = [
            "julia",
            "-e",
            "using Bzip2_jll, Crayons; println(Crayon(bold = true), \"hello from \", Bzip2_jll.libbzip2_path)",
        ],
        env = n("image_env"),
        tars = [
            n("dist_layer"),
            n("depot_layer"),
            n("compiled_layer"),
            n("app_layer"),
        ],
    )

    # --- what the image is made of --------------------------------------------------------
    sh_test(
        name = n("image_layers") + "_test",
        size = "small",
        srcs = ["image_layers_test.sh"],
        args = [
            "$(rootpath {})".format(n("dist_layer")),
            "$(rootpath {})".format(n("depot_layer")),
            "$(rootpath {})".format(n("compiled_layer")),
            "$(rootpath {})".format(n("image_env")),
            minor,
        ],
        data = _HELPERS + [
            n("compiled_layer"),
            n("depot_layer"),
            n("dist_layer"),
            n("image_env"),
        ],
        tags = tags,
    )

    # The image's config carries the environment file and the layers, in order. This is the
    # interface between this module and rules_oci, so the test reads what rules_oci wrote.
    sh_test(
        name = n("image_config") + "_test",
        size = "small",
        srcs = ["image_config_test.sh"],
        args = [
            "$(rootpath {})".format(n("image")),
            "$(rootpath {})".format(n("image_env")),
            "$(rootpath {})".format(n("dist_layer")),
            "$(rootpath {})".format(n("depot_layer")),
            "$(rootpath {})".format(n("compiled_layer")),
            "$(rootpath {})".format(n("app_layer")),
        ],
        data = _HELPERS + [
            n("app_layer"),
            n("compiled_layer"),
            n("depot_layer"),
            n("dist_layer"),
            n("image"),
            n("image_env"),
        ],
        tags = tags,
    )

    # --- determinism ----------------------------------------------------------------------
    # The same layers again under other names: separate actions with the same inputs, so Bazel
    # builds each layer twice and the test compares the bytes.
    julia_dist_layer(
        name = n("dist_layer_again"),
        julia = julia,
    )

    julia_depot_layer(
        name = n("depot_layer_again"),
        contents = "full",
        depot = depot_repo,
        julia = julia,
        manifest = project + ":Manifest.toml",
        project = project + ":Project.toml",
    )

    julia_compiled_layer(
        name = n("compiled_layer_again"),
        image_env = n("image_env"),
        julia = julia,
        layers = [
            n("dist_layer"),
            n("depot_layer"),
            n("app_layer"),
        ],
        projects = [_APP],
    )

    sh_test(
        name = n("image_determinism") + "_test",
        size = "small",
        srcs = ["image_determinism_test.sh"],
        args = [
            "$(rootpath {})".format(n("dist_layer")),
            "$(rootpath {})".format(n("dist_layer_again")),
            "$(rootpath {})".format(n("depot_layer")),
            "$(rootpath {})".format(n("depot_layer_again")),
            "$(rootpath {})".format(n("compiled_layer")),
            "$(rootpath {})".format(n("compiled_layer_again")),
        ],
        data = _HELPERS + [
            n("compiled_layer"),
            n("compiled_layer_again"),
            n("depot_layer"),
            n("depot_layer_again"),
            n("dist_layer"),
            n("dist_layer_again"),
        ],
        tags = tags,
    )

    # --- the image starts without precompiling --------------------------------------------
    julia_precompile_test(
        name = n("precompile_check") + "_test",
        size = "medium",
        image_env = n("image_env"),
        julia = julia,
        layers = [
            n("dist_layer"),
            n("depot_layer"),
            n("compiled_layer"),
            n("app_layer"),
        ],
        projects = [_APP],
        tags = tags,
    )

    # `{root}` in `env` is the unpacked tree. The active project is reachable only through the
    # load path given here, so the packages load only when `{root}` was expanded; an unexpanded
    # entry names no directory and the check fails to find them.
    julia_precompile_test(
        name = n("precompile_check_root_env") + "_test",
        size = "medium",
        env = {"JULIA_LOAD_PATH": "{root}" + _APP + ":@stdlib"},
        image_env = n("image_env"),
        julia = julia,
        layers = [
            n("dist_layer"),
            n("depot_layer"),
            n("compiled_layer"),
            n("app_layer"),
        ],
        projects = [_APP],
        tags = tags,
    )

    # The same check on the image without its compiled layer, which must fail, to show the check
    # can fail. Tagged manual; run only by precompile_check_catches_<minor>_test.
    julia_precompile_test(
        name = n("precompile_check_without_caches"),
        image_env = n("image_env"),
        julia = julia,
        layers = [
            n("dist_layer"),
            n("depot_layer"),
            n("app_layer"),
        ],
        projects = [_APP],
        tags = ["manual"],
    )

    sh_test(
        name = n("precompile_check_catches") + "_test",
        size = "medium",
        srcs = ["expect_failure_test.sh"],
        args = [
            "$(rootpath {})".format(n("precompile_check_without_caches")),
            "Precompiling",
        ],
        data = _HELPERS + [n("precompile_check_without_caches")],
        tags = tags,
    )

    # --- a sysimage instead of caches -----------------------------------------------------
    # The other way to start without precompiling: bake the code into a sysimage and ship only the
    # artifacts beside it. This depot layer names no `depot`, so it also covers instantiating
    # against a registry fetched fresh into the clean depot.
    julia_depot_layer(
        name = n("artifacts_layer"),
        julia = julia,
        manifest = project + ":Manifest.toml",
        project = project + ":Project.toml",
    )

    # One build, two shapes: the file, and the layer that ships it.
    julia_sysimage(
        name = n("sysimage"),
        depot = depot_repo,
        julia = julia,
        manifest = project + ":Manifest.toml",
        packages = [
            "Bzip2_jll",
            "Crayons",
        ],
        project = project + ":Project.toml",
    )

    julia_sysimage_layer(
        name = n("sysimage_layer"),
        sysimage = n("sysimage"),
    )

    julia_precompile_test(
        name = n("sysimage_check") + "_test",
        size = "medium",
        image_env = n("image_env"),
        julia = julia,
        layers = [
            n("dist_layer"),
            n("artifacts_layer"),
            n("sysimage_layer"),
            n("app_layer"),
        ],
        projects = [_APP],
        sysimage = "/opt/julia-sysimage/sys.so",
        tags = tags,
    )

    # The sysimage above names no compiler, so the module's pinned one linked it, and the layer
    # ships those same bytes rather than a second build.
    sh_test(
        name = n("sysimage_link") + "_test",
        size = "small",
        srcs = ["sysimage_link_test.sh"],
        args = [
            "$(rootpath {})".format(n("sysimage_layer")),
            "/opt/julia-sysimage/sys.so",
            "$(rootpath {})".format(n("sysimage")),
        ],
        data = _HELPERS + [
            n("sysimage"),
            n("sysimage_layer"),
        ],
        tags = tags,
    )
