"""JuliaDepotInfo: what a julia.depot repository was fetched for, as its default target provides it.

A julia.depot repository is fetched for one Julia and one project. The rules that build from a
depot take only the depot and read both from here, so they cannot be given a Julia or a Manifest
the depot was not instantiated for. The repository keeps its own copies of the project's
Project.toml, its `project_srcs` and its Manifest, all watched, so an edit refetches and the
copies follow it.

julia_depot_info is internal: the depot repository's BUILD file is its only caller.
"""

JuliaDepotInfo = provider(
    doc = "A julia.depot repository: the Julia and the project it was instantiated for.",
    fields = {
        "julia": "depset of Files: the Julia distribution.",
        "julia_bin": "File: its bin/julia.",
        "julia_dist": "File: its julia_dist.txt, the tarball it was fetched from.",
        "project": "File: the Project.toml the depot was fetched for.",
        "manifest": "File: the Manifest it was fetched for.",
        "project_dir": "string: the short path of the directory the project lives in, which `srcs` must be under.",
        "project_srcs": "list of struct(rel, file): the further files a resolve reads (workspace members' Project.toml), at their paths relative to the project.",
        "env": "File: env.sh.",
        "stamp": "File: stamp.txt.",
    },
)

def _find(files, name, what, label):
    for f in files:
        if f.owner.name == name:
            return f
    fail("julia: {} has no {}; pass a julia.dist repository, e.g. @julia_dist ({})".format(label, name, what))

def _julia_depot_info_impl(ctx):
    julia = ctx.files.julia
    return [
        DefaultInfo(files = depset([ctx.file.env, ctx.file.stamp])),
        JuliaDepotInfo(
            julia = depset(julia),
            julia_bin = _find(julia, "bin/julia", "the launcher", ctx.attr.julia.label),
            julia_dist = _find(julia, "julia_dist.txt", "the tarball it was fetched from", ctx.attr.julia.label),
            project = ctx.file.project,
            manifest = ctx.file.manifest,
            project_dir = ctx.attr.project_dir,
            project_srcs = [struct(rel = f.owner.name.removeprefix("project/"), file = f) for f in ctx.files.project_srcs],
            env = ctx.file.env,
            stamp = ctx.file.stamp,
        ),
    ]

julia_depot_info = rule(
    implementation = _julia_depot_info_impl,
    attrs = {
        "julia": attr.label(mandatory = True, allow_files = True),
        "project": attr.label(mandatory = True, allow_single_file = True),
        "manifest": attr.label(mandatory = True, allow_single_file = True),
        "project_dir": attr.string(),
        "project_srcs": attr.label_list(allow_files = True),
        "env": attr.label(mandatory = True, allow_single_file = True),
        "stamp": attr.label(mandatory = True, allow_single_file = True),
    },
)
