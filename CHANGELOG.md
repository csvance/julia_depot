# Changelog

Each release has a section here, written before it is tagged. The section for a version
becomes its GitHub release notes and the body of its Bazel Central Registry pull request;
see `.github/workflows/release_notes.sh` and `bcr_notes.sh`.

## 0.2.0

This release makes sysimages hermetic in what they link, and makes the Starlark rules the
module's whole interface.

- **Hermetic sysimage builds.** A sysimage used to be linked by whatever C compiler the host
  had, an input no cache key covered, so hosts sharing a remote cache could serve each other
  sysimages linked against a different compiler and glibc. It is now linked by a pinned
  compiler that is an input of the action: zig 0.16.0, fetched by sha256, linking against
  glibc 2.17, so a sysimage loads on any host with glibc 2.17 or later. The sysimage rules also
  run sandboxed: the depot is only read, and anything the build writes goes to a scratch depot.
  A sysimage is still not bit-reproducible, so each one now comes with an inputs file, its
  declared inputs by sha256, which is the same for every build of the same inputs on any host.
- **A Starlark interface.** Everything a build needs is a rule or a tag: `julia_sysimage`
  writes a sysimage as a file, so no build calls `sysimage.sh` or `image_depot.sh` any more.
  Both scripts are now internal, free to change in any release like the module's other
  scripts.

`compatibility_level` is now 2. Every module in a graph must agree on it, so a module and the
modules it depends on move to 0.2.0 together. A root `git_override` or `local_path_override` of
julia_depot applies to every module in the graph, so it carries a dependency that still asks
for 0.1.x through the transition.

### Breaking

- `sysimage.sh` and `image_depot.sh` are internal. Replace a genrule that calls one with the
  rule that runs it:
  - `sysimage.sh` → `julia_sysimage`, or `julia_sysimage_layer` for an image. `srcs` are the
    project's files; a file outside the project goes in `data`, and `env` can name it as
    `"{execroot}/$(execpath <label>)"`. Drop the genrule's `no-sandbox` tag along with it.
  - `image_depot.sh` → `julia_depot_layer`, with `depot` for the registries and server
    credentials, and `contents`, `prefix`, `min_artifacts` and `overrides_build` /
    `overrides_image` in place of the script's `JULIA_DEPOT_*` variables.
- Sysimages are linked by the pinned compiler `@julia_depot_cc` unless the rule is given `cc`
  (another compiler) or `system_cc = True` (the host's, which prints a warning and tags the
  action `no-remote-cache`). Nothing to change for a build that wants the pinned compiler.
- The `RULES_JULIA_DEPOT_*` spellings are removed, as 0.1.1 announced: a hook is given only
  `JULIA_DEPOT_BIN`.

### Fixed

- On Julia 1.10, a `julia.depot` with `dir` exported `<dir>:` with a trailing separator, which
  1.10 expands to its whole default path, the user depot `~/.julia` included. Julia then read
  packages from `~/.julia` behind `dir`, and Pkg installed nothing into `dir` that `~/.julia`
  already held. The bundled depots are now named instead on 1.10; 1.11 and later, where a
  trailing separator means the bundled depots alone, are unchanged.

### New

- `julia_sysimage`: a sysimage as a file, `<name>.so`, to start Julia with.
- `julia.cc` declares another pinned compiler, for a different zig version or glibc target:
  `julia.cc(name = "my_cc", glibc = "2.28")`, then `cc = "@my_cc"` on a sysimage rule.
- An inputs file for every sysimage, `<name>.inputs.json` in the `inputs` output group, shipped
  by `julia_sysimage_layer` beside the sysimage: the Julia tarball, the compiler, the
  PackageCompiler environment, and each declared input by sha256, with no host paths.
  `bazel build --output_groups=inputs` writes it without building the sysimage, to check a
  rebuild against a release.
- `data` on `julia_sysimage` and `julia_sysimage_layer`, for build inputs outside the project,
  and `$(execpath ...)` and `{execroot}` expansion in their `env`.

## 0.1.1

### New

- `julia.depot` takes `read_only_depots`: depots searched after `dir` and never written to,
  such as a host's shared depot. Pkg installs into `dir` only what they lack. Requires `dir`;
  an entry that does not exist is skipped. Their contents are not watched, so if a shared
  depot loses something `dir` relied on, run `bazel fetch --force @<name>`.
- `image_depot.sh` copies registries from every entry of `JULIA_DEPOT_PATH`, not just the
  first, so a registry held only in a read-only depot still reaches the image.
- `julia.dist` knows the checksums for Julia 1.10.12 and 1.13.1, so `sha256` can be omitted
  for them.

### Deprecated

- The `RULES_JULIA_DEPOT_*` variables are renamed `JULIA_DEPOT_*`. This covers the inputs to
  `image_depot.sh` and `sysimage.sh` and the `RULES_JULIA_DEPOT_BIN` a depot hook receives.
  The old names still work: the scripts accept them with a warning, and hooks receive both
  names. They will be removed when `compatibility_level` is next raised.

### Changed

- A `dir` containing `:` is now an error. It used to be split silently into two depot path
  entries.
- Supported Julia versions are now the LTS and the two most recent releases. 1.10 (LTS) is
  tested in CI. It has no bundled PackageCompiler environment, so `sysimage.sh auto` does
  not work on 1.10.

## 0.1.0

Initial release.
