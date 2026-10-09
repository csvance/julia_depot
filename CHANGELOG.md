# Changelog

Each release has a section here, written before it is tagged. The section for a version
becomes its GitHub release notes and the body of its Bazel Central Registry pull request;
see `.github/workflows/release_notes.sh` and `bcr_notes.sh`.

## 0.2.0

`compatibility_level` is now 2. Every module in a graph must agree on it, so a module and
the modules it depends on move to 0.2.0 together. A root `git_override` or
`local_path_override` of julia_depot applies to every module in the graph, so it carries a
dependency that still asks for 0.1.x through the transition.

### Breaking

- **A sysimage is linked by a declared compiler.** PackageCompiler used to link with whatever
  g++, clang++, gcc or clang was on the host's `PATH`, which was not an input of the action,
  so two hosts could produce different sysimages under the same cache key. The module now
  ships a pinned one, `@julia_depot_cc`: zig 0.16.0 fetched by sha256, linking against glibc
  2.17, so a sysimage loads on any host with glibc 2.17 or later. The host's compiler is
  available by opt-in only.
  - `julia_sysimage_layer`: nothing to change. It links with `@julia_depot_cc` unless given
    `cc` (another compiler) or `system_cc = True` (the host's, with the action tagged
    `no-remote-cache`).
  - A genrule calling `sysimage.sh`: `JULIA_DEPOT_SYSIMAGE_CC` is now required. Add
    `use_repo(julia, "julia_depot_cc")` to `MODULE.bazel`, add `@julia_depot_cc//:cc` and
    `@julia_depot_cc//:bin/cc` to the genrule's `srcs`, and
    `export JULIA_DEPOT_SYSIMAGE_CC="$(location @julia_depot_cc//:bin/cc)"` before calling the
    script. See the sysimage recipe. `JULIA_DEPOT_SYSIMAGE_CC=system` restores the old
    behaviour, with a warning.
  - A module using only the depot, the dist or the other layers: bump the `bazel_dep`.
- The `RULES_JULIA_DEPOT_*` spellings are removed, as 0.1.1 announced: `image_depot.sh` and
  `sysimage.sh` read only `JULIA_DEPOT_*`, and a hook is given only `JULIA_DEPOT_BIN`.

### New

- `julia.cc` declares a pinned C compiler for sysimages, for another zig version or glibc
  target: `julia.cc(name = "my_cc", glibc = "2.28")`, then `cc = "@my_cc"` on
  `julia_sysimage_layer`. It provides `:cc` and `bin/cc` like `julia.dist` provides `:dist`
  and `bin/julia`.

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
