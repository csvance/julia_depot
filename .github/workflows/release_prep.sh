#!/usr/bin/env bash
# Builds the release archive for a tag and prints the release notes, for
# bazel-contrib/.github's release_ruleset workflow, which calls this path by name.
#
# The archive's prefix matches what GitHub generates for source archives, so
# .bcr/source.template.json's strip_prefix is the same either way.

set -o errexit -o nounset -o pipefail

TAG=$1
VERSION=${TAG#v}
PREFIX="rules_julia_depot-${VERSION}"
ARCHIVE="rules_julia_depot-${TAG}.tar.gz"

# The tag and MODULE.bazel must agree. publish-to-bcr would patch the registry copy to
# match the tag, but then the archive and the docs site would both claim another version.
declared="$(git show "${TAG}:MODULE.bazel" | sed -n 's/^ *version = "\([^"]*\)".*/\1/p' | head -n 1)"
if [[ "${declared}" != "${VERSION}" ]]; then
  echo "tag ${TAG} does not match MODULE.bazel version \"${declared}\"" >&2
  exit 1
fi

# Excludes come from .gitattributes.
git archive --format=tar --prefix="${PREFIX}/" "${TAG}" | gzip -n > "${ARCHIVE}"

cat <<NOTES
## Bzlmod

Add to your \`MODULE.bazel\` file:

\`\`\`starlark
bazel_dep(name = "rules_julia_depot", version = "${VERSION}")
\`\`\`

Documentation for this release: https://csvance.github.io/rules_julia_depot/${TAG}/
NOTES
