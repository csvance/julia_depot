# Shared helpers for the julia_depot end-to-end tests. Sourced, never executed.
#
# Runfiles arrive as paths relative to the test's working directory, and every script under test
# changes directory, so tests make paths absolute first (abspath). Runfiles are symlinks into the
# source tree, so a project directory is copied before Pkg is pointed at it (copy_project): Pkg
# writes to the project it is given, and the manifests in this repository are the pins under test.

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

abspath() {
    local p="$1"
    [ -e "$p" ] || fail "no such runfile: $p (working directory $PWD)"
    printf '%s/%s\n' "$(cd "$(dirname "$p")" && pwd)" "$(basename "$p")"
}

# The value of one key from a stamp.txt written by instantiate.sh.
stamp_value() {
    local stamp="$1" key="$2"
    local v
    v="$(sed -n "s/^${key}=//p" "$stamp")"
    [ -n "$v" ] || fail "stamp $stamp has no $key= line"
    printf '%s\n' "$v"
}

# The first entry of a possibly colon-joined depot path, which is the one Julia writes to
# and the one image_depot.sh treats as the source depot.
first_depot() {
    printf '%s\n' "${1%%:*}"
}

# The two depots a Julia distribution ships inside itself (<prefix>/local/share/julia and
# <prefix>/share/julia). The second holds the stdlib precompile caches: a depot path that
# omits it makes `using Pkg` recompile Pkg serially, about 80 s on a fast machine and
# several minutes on a CI runner, before anything else can happen.
bundled_depots() {
    local julia_bin="$1" prefix
    prefix="$(cd "$(dirname "$(readlink -f "$julia_bin")")/.." && pwd)"
    printf '%s:%s\n' "$prefix/local/share/julia" "$prefix/share/julia"
}

# A depot path with a writable depot first, the already-instantiated one behind it for reads, and,
# when the julia binary is passed, the distribution's bundled depots after that. Tests run
# sandboxed, where the real depot is visible but read-only, so anything Julia precompiles along
# the way must be written elsewhere.
overlay_depot() {
    local src="$1" julia_bin="${2:-}"
    mkdir -p "$TEST_TMPDIR/overlay-depot"
    if [ -n "$julia_bin" ]; then
        printf '%s:%s:%s\n' "$TEST_TMPDIR/overlay-depot" "$src" "$(bundled_depots "$julia_bin")"
    else
        printf '%s:%s\n' "$TEST_TMPDIR/overlay-depot" "$src"
    fi
}

# A writable copy of the project a Manifest runfile belongs to.
copy_project() {
    local manifest="$1" dest="$2"
    local src
    src="$(dirname "$manifest")"
    mkdir -p "$dest"
    cp -L "$src/Project.toml" "$src/Manifest.toml" "$dest/"
    chmod u+w "$dest/Project.toml" "$dest/Manifest.toml"
    printf '%s\n' "$dest"
}

# Julia and PackageCompiler both call homedir(), which throws when HOME is unset, and a
# test action is not given one.
export HOME="${TEST_TMPDIR:?tests run under bazel test}/home"
mkdir -p "$HOME"
