#!/usr/bin/env bash
# What a fresh public clone must be able to rely on in the task runner: a recipe
# that publishes under the maintainer's accounts refuses to start without the
# maintainer's say-so, and one that ships the engine first checks the VGraph
# checkout it ships from. VGraph's own justfile is held to the same.
set -uo pipefail

cd "$(dirname "$0")/.."
FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }

out=$(just --dump --dump-format json | python3 -c '
import json, sys
recipes = json.load(sys.stdin)["recipes"]
def deps(name): return [d["recipe"] for d in recipes[name].get("dependencies", [])]
for name, r in recipes.items():
    in_publish = any(a.get("group") == "publish" for a in r.get("attributes", []) if isinstance(a, dict))
    # build-cloud-image-local builds locally and pushes nothing under anyone.
    if in_publish and name != "build-cloud-image-local" and "_require-maintainer" not in deps(name):
        print(name + " does not require the maintainer")
for name in ("publish", "publish-node", "publish-cloud-run"):
    if deps(name)[:2] != ["_require-maintainer", "_require-vgraph-main"]:
        print(name + " does not check VGraph before it builds: " + " ".join(deps(name)))
# Publishing ships what `just release` built and checked; it compiles nothing.
for name in ("publish", "publish-node"):
    for compiling in ("build", "node"):
        if compiling in deps(name): print(name + " compiles again: depends on " + compiling)
if "_vendor" not in deps("publish-node"): print("publish-node does not vendor the released engine")
body = json.dumps(recipes["_vendor"]["body"])
if "check-engine-build.sh" not in body: print("_vendor does not check the engine against the recorded build")
# Only dump-mcp-tools runs the server here, and a debug build answers the same.
if "config=release" in json.dumps(recipes["release"]["body"]): print("release compiles the servers optimised")
# Cloud Build runs only for sources no image was built from, and the deploy
# rolls out the image that was built or found.
if "scripts/cloud-image.sh build" not in json.dumps(recipes["build-cloud-image"]["body"]): print("build-cloud-image does not skip an image that exists")
if ".build/cloud-image" not in json.dumps(recipes["publish-cloud-run"]["body"]): print("publish-cloud-run does not deploy the image that was built")
')
[ -z "$out" ] || fail "$out"

env -u VITHANCO_MAINTAINER just _require-maintainer >/dev/null 2>&1 \
    && fail "_require-maintainer passed without VITHANCO_MAINTAINER"
VITHANCO_MAINTAINER=1 just _require-maintainer >/dev/null 2>&1 \
    || fail "_require-maintainer failed with VITHANCO_MAINTAINER=1"

[ "$FAILED" -eq 0 ] && echo "✓ justfile hygiene"
exit "$FAILED"
