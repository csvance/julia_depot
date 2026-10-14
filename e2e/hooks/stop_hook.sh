#!/usr/bin/env bash
# A julia_depot `hook` that fails the fetch on purpose, for bundled_warning_test.sh.
#
# The hook runs after the rule has settled the depot path and printed any warning about it, and
# before instantiate. Stopping here lets that script see the warning in seconds, without the
# instantiate (and the stdlib recompile the warning is about) that a depot path with no bundled
# depots would otherwise cost.
echo "stop_hook: stopping the fetch before instantiate, as bundled_warning_test.sh expects" >&2
exit 1
