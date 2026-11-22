#!/usr/bin/env bash
# The Swift half of CI, inside swift:<VGraph's .swift-version>-noble, run from
# this checkout inside VGraph's, as on the maintainer's machine.
set -euo pipefail

cd "$(dirname "$0")/.."

apt-get update
# python3: dump-mcp-tools.sh. rsvg-convert and the fonts: the PNG tests convert
# as the server image does.
apt-get install -y --no-install-recommends curl ca-certificates git python3 \
    librsvg2-bin fontconfig fonts-liberation

# Ubuntu's own just is too old for the justfile's [group] attribute.
JUST=just-1.59.0-x86_64-unknown-linux-musl.tar.gz
SHA256=409044617b6f06517c1035e55ca38c8c856ff8b650e41bc2aa1ef82d5903a23e
TARBALL=$(mktemp)
curl -fsSL -o "$TARBALL" "https://github.com/casey/just/releases/download/1.59.0/$JUST"
echo "$SHA256  $TARBALL" | sha256sum -c -
tar -xzf "$TARBALL" -C /usr/local/bin just
rm "$TARBALL"

# Root in the container does not own the checkout.
git config --global --add safe.directory "$PWD"

just lint
swift build --build-tests
# A stale generated file fails the pull request that made it stale.
./scripts/check-generated.sh
# These two assume Linux means "inside the server image", and describe an
# image that does not exist: it has no dot and runs as root.
swift test --skip-build --skip 'DockerIntegrationTests/test(DockerBuildSucceeds|NonRootUserExecution)'
