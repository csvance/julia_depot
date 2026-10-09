#!/usr/bin/env bash
# Fails if any file that would be published contains a private reference.
#
# This module was extracted from a closed repository, and what leaks from such an extraction
# is textual: an internal hostname in an example, a package server URL in a comment, an
# absolute path from a developer's machine in a committed file. None of these breaks a build
# or a test, so this check searches for them.
#
# Patterns: the committed ones, in private_ref_patterns.txt beside this file, are generic,
# because a committed list of one organisation's hostnames would publish those hostnames.
# Put site-specific literals in an uncommitted file of your own and name it in
# PRIVATE_REF_PATTERNS_EXTRA, which is read when set.
#
# Scope: the tree as it would be published, meaning files git tracks plus untracked files
# that are not ignored, since those are one `git add` away. Ignored files are skipped, which
# keeps bazel-out, a Julia depot and MODULE.bazel.lock out of the scan. The pattern files are
# excluded because each pattern matches itself.
#
# Run it from anywhere in the repository. It lists every hit and exits non-zero.
set -euo pipefail

cd "$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

pattern_files=("tools/private_ref_patterns.txt")
[ -z "${PRIVATE_REF_PATTERNS_EXTRA:-}" ] || pattern_files+=("$PRIVATE_REF_PATTERNS_EXTRA")

patterns=()
for f in "${pattern_files[@]}"; do
    [ -f "$f" ] || {
        echo "no pattern file at $f" >&2
        exit 1
    }
    while IFS= read -r line; do
        case "$line" in "" | \#*) continue ;; esac
        patterns+=("$line")
    done < "$f"
done
[ "${#patterns[@]}" -gt 0 ] || {
    echo "no patterns to check for" >&2
    exit 1
}

files="$(git ls-files --cached --others --exclude-standard |
    grep -vxF -e "tools/private_ref_patterns.txt" -e "${PRIVATE_REF_PATTERNS_EXTRA:-/dev/null}")"
[ -n "$files" ] || {
    echo "no files to check" >&2
    exit 1
}

status=0
for pattern in "${patterns[@]}"; do
    hits="$(printf '%s\n' "$files" | tr '\n' '\0' |
        xargs -0 grep -InE -- "$pattern" 2> /dev/null || true)"
    if [ -n "$hits" ]; then
        echo "FAILED: this repository is public and /$pattern/ matched:" >&2
        printf '%s\n' "$hits" >&2
        echo >&2
        status=1
    fi
done

if [ "$status" -ne 0 ]; then
    echo "Remove the reference, or narrow the pattern if it is a false positive." >&2
    exit 1
fi

echo "OK: $(printf '%s\n' "$files" | wc -l) files against ${#patterns[@]} patterns, nothing private"
