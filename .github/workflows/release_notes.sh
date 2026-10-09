#!/usr/bin/env bash
# Prints one version's notes from CHANGELOG.md: its `## <version>` section without the
# heading, with the remaining headings raised one level for the top of a release or pull
# request body.
#
# Usage: release_notes.sh <version> [<changelog>]
#
# Fails when the section is missing or empty. This is the only source of the notes:
# release_prep.sh puts them in the GitHub release and release.yaml, through bcr_notes.sh, in the
# BCR pull request. ci.yml runs this on MODULE.bazel's version, so a version bump without notes
# fails before it is tagged.

set -o errexit -o nounset -o pipefail

VERSION="${1:?usage: release_notes.sh <version> [<changelog>]}"
CHANGELOG="${2:-CHANGELOG.md}"

# Join wrapped lines, because GitHub renders a newline in a release or pull request body as a
# line break. A line continues the one before it unless either is blank, it starts a heading,
# list item, table row or quote, or it is inside a code fence.
notes="$(awk -v heading="## ${VERSION}" '
    function flush() { if (held != "") print held; held = "" }
    $0 == heading { inside = 1; next }
    inside && /^## / { exit }
    !inside { next }
    /^```/ { flush(); print; fence = !fence; next }
    fence { print; next }
    /^[[:space:]]*$/ { flush(); print ""; next }
    /^#/ { flush(); sub(/^###/, "##"); print; next }
    /^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]/ { flush(); held = $0; next }
    /^[[:space:]]*[|>]/ { flush(); held = $0; next }
    held != "" { sub(/^[[:space:]]+/, ""); held = held " " $0; next }
    { held = $0 }
    END { flush() }
' "${CHANGELOG}")"

# Trim the blank lines around the section; an all-blank section counts as missing.
notes="$(printf '%s\n' "${notes}" | sed -e '/./,$!d' | tac | sed -e '/./,$!d' | tac)"
if [[ -z "${notes}" ]]; then
  echo "${CHANGELOG} has no notes for ${VERSION}: add a \"## ${VERSION}\" section" >&2
  exit 1
fi
printf '%s\n' "${notes}"
