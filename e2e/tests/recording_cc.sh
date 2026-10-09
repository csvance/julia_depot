#!/usr/bin/env bash
# A user-supplied compiler, as a test fixture: it records each call in E2E_CC_LOG, then hands the
# call to E2E_CC_NEXT, the pinned compiler. A record proves sysimage.sh used the compiler it was
# given rather than one of its own choosing.
set -euo pipefail
: "${E2E_CC_LOG:?the test sets E2E_CC_LOG}"
: "${E2E_CC_NEXT:?the test sets E2E_CC_NEXT}"
printf '%s\n' "$*" >> "$E2E_CC_LOG"
exec "$E2E_CC_NEXT" "$@"
