#!/usr/bin/env bash
# What rules_oci wrote: the image's config carries the environment file and the layers, in order.
#
# Usage: image_config_test.sh <oci layout> <image env> <layer.tar>...
#
# The module stops at a tar and an environment file; this is where they meet rules_oci, so the
# check is made on the OCI layout it produced. Every variable in the environment file is in the
# config, PATH with the base image's own PATH expanded into it rather than a literal $PATH, and the
# image's last layers are these tars, in this order, by the digest of their uncompressed bytes
# (the config's diff_ids), whatever compression the registry copy uses.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../tests/common.sh"

layout="$(abspath "$1")"
image_env="$(abspath "$2")"
shift 2
digests=()
for t in "$@"; do
    digests+=("sha256:$(sha256sum < "$(abspath "$t")" | cut -d' ' -f1)")
done

python3 - "$layout" "$image_env" "${digests[@]}" <<'PY'
import json, os, sys

layout, env_file, want_layers = sys.argv[1], sys.argv[2], sys.argv[3:]

def blob(digest):
    algo, hexd = digest.split(":")
    with open(os.path.join(layout, "blobs", algo, hexd)) as f:
        return json.load(f)

index = json.load(open(os.path.join(layout, "index.json")))
manifest = blob(index["manifests"][0]["digest"])
config = blob(manifest["config"]["digest"])

env = dict(e.split("=", 1) for e in config["config"].get("Env", []))
problems = []
for line in open(env_file).read().splitlines():
    key, value = line.split("=", 1)
    got = env.get(key)
    if key == "PATH":
        if not got or not got.startswith("/opt/julia/bin:") or "$" in got:
            problems.append(f"PATH={got!r}, expected /opt/julia/bin: then the base image's PATH")
    elif got != value:
        problems.append(f"{key}={got!r}, expected {value!r}")

diff_ids = config["rootfs"]["diff_ids"]
if diff_ids[-len(want_layers):] != want_layers:
    problems.append(f"the last layers are {diff_ids[-len(want_layers):]}, expected {want_layers}")

if problems:
    print("FAIL: " + "\n      ".join(problems), file=sys.stderr)
    sys.exit(1)
print(f"PASS: {len(env)} variables and {len(diff_ids)} layers, the last {len(want_layers)} ours, in order")
PY
