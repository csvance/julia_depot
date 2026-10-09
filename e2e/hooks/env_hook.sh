#!/usr/bin/env bash
# A julia_depot `hook` used as a test fixture: it fails the fetch unless the depot's `env` reached
# it. The rule runs the hook and the instantiate with the same environment, so a fetch that
# succeeds is evidence that `env` reached the instantiate too.
set -euo pipefail
[ "${E2E_DEPOT_ENV:-}" = "julia-depot-e2e-env" ] || {
    echo "julia_depot did not pass the depot's env to the fetch: E2E_DEPOT_ENV='${E2E_DEPOT_ENV:-}'" >&2
    exit 1
}
echo "env_hook: E2E_DEPOT_ENV reached the fetch"
