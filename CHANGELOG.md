# Changelog

Each release has a section here, written before it is tagged. The section for a version
becomes its GitHub release notes and the body of its Bazel Central Registry pull request;
see `.github/workflows/release_notes.sh`.

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
