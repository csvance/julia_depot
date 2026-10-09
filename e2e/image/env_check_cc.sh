#!/usr/bin/env bash
# A compiler given to julia_sysimage as a plain file, as a test fixture. It runs inside the build,
# so it checks what the rule promised the build would see, and fails the link when it is not so:
# E2E_DATA, set in `env` from "{execroot}/$(execpath ...)", is an absolute path to the data file;
# E2E_CC_NEXT names the pinned compiler the same way, and the call is handed to it.
set -euo pipefail
case "${E2E_DATA:-}" in
    /*) ;;
    *) echo "env_check_cc: E2E_DATA is '${E2E_DATA:-}', not an absolute path; {execroot} did not expand" >&2; exit 1 ;;
esac
[ -f "$E2E_DATA" ] || { echo "env_check_cc: E2E_DATA=$E2E_DATA is not a file the build can read" >&2; exit 1; }
grep -q 'julia-depot-e2e data' "$E2E_DATA" || { echo "env_check_cc: $E2E_DATA is not the data file" >&2; exit 1; }
exec "${E2E_CC_NEXT:?julia_sysimage did not pass E2E_CC_NEXT}" "$@"
