#!/usr/bin/env bash
# Puts a release's CHANGELOG.md notes at the top of its Bazel Central Registry pull request.
#
# Usage: bcr_notes.sh <tag>      (with GH_TOKEN, or a logged-in gh, that can edit the pull request)
#
# publish-to-bcr opens the pull request with a fixed body (a link to the release) and has no
# input to change it. Registry maintainers review from that pull request. release.yaml runs this
# after publish; if that job fails, run it by hand from a checkout of the tag. The pull request
# is found by the branch publish-to-bcr pushes to the fork, <module>-<tag>. A body that already
# has the notes is left alone.
#
# Uses the REST API only. `gh pr list` and `gh pr edit` use GraphQL, which needs read:org for
# fields they query; the publish token has only `repo` and `workflow`, which is all
# publish-to-bcr needs.

set -o errexit -o nounset -o pipefail

TAG="${1:?usage: bcr_notes.sh <tag>}"
REGISTRY=bazelbuild/bazel-central-registry
# Must match publish.yaml's registry_fork and MODULE.bazel's module name.
FORK_OWNER=csvance
MODULE=julia_depot
MARKER="<!-- julia_depot release notes -->"

notes="$("$(dirname "$0")/release_notes.sh" "${TAG#v}")"

pr="$(gh api "repos/${REGISTRY}/pulls?head=${FORK_OWNER}:${MODULE}-${TAG}&state=open" --jq 'first')"
if [[ -z "${pr}" || "${pr}" == null ]]; then
  echo "no open pull request on ${REGISTRY} from ${FORK_OWNER}:${MODULE}-${TAG}" >&2
  exit 1
fi
number="$(jq -r .number <<<"${pr}")"
url="$(jq -r .html_url <<<"${pr}")"
body="$(jq -r '.body // ""' <<<"${pr}")"

if [[ "${body}" == *"${MARKER}"* ]]; then
  echo "${url} already has the notes"
  exit 0
fi

new_body="$(printf '%s\n%s\n\n---\n\n%s\n' "${MARKER}" "${notes}" "${body}")"
jq -n --arg body "${new_body}" '{body: $body}' |
  gh api --method PATCH "repos/${REGISTRY}/pulls/${number}" --input - --jq .html_url >/dev/null
echo "notes added to ${url}"
