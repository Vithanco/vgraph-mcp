# vgraph-mcp task runner. This repository is cloned inside a VGraph checkout
# (VGraph's `just plugins-setup`) and builds against it as `..`; VGraph's
# `just mcp <recipe>` runs any recipe here. Why: VGraph's ADR 0040.
#
#   build    → both Swift servers, {{config}} config
#   test     → build + lint + swift test + shell tests + generated files (test-node: the npm host)
#   release  → what VGraph's `just release` runs here (nothing pushed)
#   publish* → outward-facing; refuses without VITHANCO_MAINTAINER=1

set positional-arguments

config        := "debug"
vgraph        := justfile_directory() / ".."
# Cloud Run image / region / service (used by the cloud recipes).
cloud_image   := env_var_or_default("VGRAPH_CLOUD_IMAGE", "europe-west1-docker.pkg.dev/vgraph-mcp/cloud-run-source-deploy/vgraph-mcp-http")
cloud_region  := env_var_or_default("VGRAPH_CLOUD_REGION", "europe-west1")
cloud_service := env_var_or_default("VGRAPH_CLOUD_SERVICE", "vgraph-mcp")

default:
    @just --list

# Build both MCP servers (stdio and HTTP) in {{config}} config.
[group('build')]
build:
    swift build -c {{config}}

# Assemble the npm host: build the release engine in VGraph, then vendor it.
[group('build')]
node: build
    #!/usr/bin/env bash
    set -euo pipefail
    # Always release, regardless of `config`. This vendors what npm publishes,
    # and the debug module is 78MB against 4.1MB.
    just --justfile "{{vgraph}}/justfile" wasm --release --skip-smoke
    just _vendor

# Copy the engine VGraph last built, and the fonts, into vendor/; refresh tools.json.
_vendor:
    #!/usr/bin/env bash
    set -euo pipefail
    # Vendored rather than committed: the wasm is 4.1MB, and a copy in git is a
    # copy that can disagree with the engine it was built from. Same reason the
    # plugins re-copy it from website/Package on every build.
    rm -rf vendor
    mkdir -p vendor
    cp -R "{{vgraph}}/website/Package" vendor/Package
    cp -R "{{vgraph}}/fonts" vendor/fonts
    # Belt and braces: catches the day someone vendors a debug build.
    WASM_BYTES=$(wc -c < vendor/Package/VGraphWasm.wasm)
    if [ "$WASM_BYTES" -gt 20000000 ]; then
        echo "Error: vendored wasm is $WASM_BYTES bytes — that is a debug build." >&2
        exit 1
    fi
    ./scripts/dump-mcp-tools.sh
    echo "✓ npm host vendored ($(du -sh vendor | cut -f1))"

# Regenerate every tracked file the build generates (today tools.json). CI fails while one is stale.
[group('build')]
regen: build
    ./scripts/check-generated.sh --write

# What VGraph's `just release` runs here, after it built the release engine: release servers, the npm host, generated files.
[group('build')]
release:
    just config=release build
    just _vendor
    ./scripts/check-generated.sh

# build + lint + swift test + shell tests + generated files are current.
[group('test')]
test: build lint
    swift test --skip 'DockerIntegrationTests/test(DockerBuildSucceeds|NonRootUserExecution)'
    ./scripts/check-generated.test.sh
    ./scripts/mcp-registry.test.sh
    ./scripts/justfile-hygiene.test.sh
    ./scripts/check-generated.sh

# The npm host's tests, against the release engine it vendors.
[group('test')]
test-node: node
    [ -d node_modules ] || npm install --silent; npm test

# Fail on any formatting deviation (VGraph's .swift-format rules).
[group('test')]
lint:
    swift format lint -r --strict --configuration .swift-format Sources Tests

# Format all Swift sources in place — what to run when `just lint` goes red.
[group('test')]
format:
    swift-format -r -i --configuration .swift-format Sources Tests

# Run the stdio server.
[group('run')]
run:
    VGRAPH_LOG_LEVEL=debug swift run vgraph-mcp

# Run the npm host against the current engine build (stdio; Ctrl-C to stop).
[group('run')]
node-run: node
    [ -d node_modules ] || npm install --silent; node src/server.mjs

# Build the LOCAL release stdio binary for Claude Desktop (distinct from the cloud image).
[group('run')]
local-server:
    #!/usr/bin/env bash
    set -euo pipefail
    just format
    swift test --filter VGraphMCPTests
    swift build --product vgraph-mcp -c release
    echo ""
    echo "✓ Binary: .build/release/vgraph-mcp"
    ls -lh .build/release/vgraph-mcp | awk '{print "  " $5 " - " $9}'
    echo "  Quit & relaunch Claude Desktop to reload the server."

# ═══════════════════════════════════════════════════════════════════════════
# Publish (outward-facing — the only irreversible recipes)
# ═══════════════════════════════════════════════════════════════════════════

# Commit the version bump, tag and push it, then npm + the MCP Registry, then Cloud Run. Each step skips once done, so a rerun finishes a half-done publish.
[group('publish')]
publish: _require-maintainer _require-vgraph-main _require-main
    #!/usr/bin/env bash
    set -euo pipefail
    VER=$(node -p "require('./package.json').version")
    if git rev-parse -q --verify "refs/tags/$VER" >/dev/null; then
        echo "· vgraph-mcp already tagged $VER — skipping"
    else
        # The engine this release ships, as VGraph's build recorded it.
        read -r BUILT _ < "{{vgraph}}/website/Package/VGRAPH_BUILD"
        git add package.json server.json LICENSE NOTICE
        git diff --cached --quiet || git commit -m "chore: release $VER"
        git tag -a "$VER" -m "Release $VER, engine VGraph ${BUILT:0:12}"
        git push origin HEAD "refs/tags/$VER"
    fi
    # Both, not npm alone: npm and the registry are two publishes, and skipping
    # on npm kept a failed registry publish from ever being retried.
    if [ "$(npm view "$(node -p "require('./package.json').name")" version 2>/dev/null)" = "$VER" ] \
       && ./scripts/mcp-registry.sh --has; then
        echo "· npm and the MCP Registry already at $VER — skipping"
    else
        just publish-node
    fi
    just publish-cloud-run

# Publish the npm host to npm, then list it in the MCP Registry.
[group('publish')]
publish-node otp='': _require-maintainer _require-vgraph-main node
    #!/usr/bin/env bash
    set -euo pipefail
    PKG=$(node -p "require('./package.json').name")
    VER=$(node -p "require('./package.json').version")

    # Preflight: everything that can fail, before anything is published. An npm
    # version cannot be re-published once taken, so discovering a problem
    # halfway through leaves a burnt version number behind.
    FAIL=0

    if ! npm whoami >/dev/null 2>&1; then
        echo "Preflight: not logged in to npm — run 'npm login'." >&2
        FAIL=1
    fi

    # Not a failure: npm and the registry are two publishes, and the first run
    # got npm out and then died on an expired registry token. Aborting here
    # would have made the recipe unable to finish its own half-done work.
    NPM_DONE=0
    if npm view "$PKG@$VER" version >/dev/null 2>&1; then
        NPM_DONE=1
    fi

    # The registry verifies a server by matching `mcpName` in the *published*
    # package against the name in server.json. Getting this wrong is only
    # discoverable after npm has taken the version.
    MCP_NAME=$(node -p "require('./package.json').mcpName || ''")
    SRV_NAME=$(node -p "require('./server.json').name")
    SRV_VER=$(node -p "require('./server.json').version")
    SRV_PKG_VER=$(node -p "require('./server.json').packages[0].version")
    if [ "$MCP_NAME" != "$SRV_NAME" ]; then
        echo "Preflight: package.json mcpName ($MCP_NAME) != server.json name ($SRV_NAME)." >&2
        FAIL=1
    fi
    if [ "$SRV_VER" != "$VER" ] || [ "$SRV_PKG_VER" != "$VER" ]; then
        echo "Preflight: server.json versions ($SRV_VER / $SRV_PKG_VER) != package.json ($VER)." >&2
        FAIL=1
    fi

    # `just node` ran above, so these should hold — they catch someone
    # publishing from a tree where it half-failed.
    WASM="vendor/Package/VGraphWasm.wasm"
    if [ ! -f "$WASM" ]; then
        echo "Preflight: $WASM missing — 'just node' did not complete." >&2
        FAIL=1
    elif [ "$(wc -c < "$WASM")" -gt 20000000 ]; then
        echo "Preflight: $WASM is a debug build." >&2
        FAIL=1
    fi
    if [ ! -s tools.json ] || [ "$(node -p "require('./tools.json').length")" -eq 0 ]; then
        echo "Preflight: tools.json is empty — scripts/dump-mcp-tools.sh did not run." >&2
        FAIL=1
    fi
    # OFL 1.1 requires the licence ship with the fonts.
    if [ ! -f vendor/fonts/OFL.txt ]; then
        echo "Preflight: vendor/fonts/OFL.txt missing — the fonts must not ship without it." >&2
        FAIL=1
    fi

    if [ "$FAIL" -ne 0 ]; then
        echo "" >&2
        echo "Nothing was published." >&2
        exit 1
    fi

    if [ "$NPM_DONE" -eq 1 ]; then
        echo "· $PKG@$VER already on npm — skipping, going straight to the registry"
    else
        echo "Publishing $PKG@$VER to npm..."
        # npm requires 2FA or a granular token with 2FA bypass to publish,
        # whatever the account's own tfa setting says. With a granular token no
        # OTP is needed; with account 2FA one is, and it must be supplied at the
        # moment of use because it expires in seconds.
        if [ -n "{{otp}}" ]; then
            npm publish --access public --otp="{{otp}}"
        else
            npm publish --access public
        fi
    fi

    echo ""
    ./scripts/mcp-registry.sh

# Build the linux/amd64 image on Cloud Build + push it (no local Docker needed).
[group('publish')]
build-cloud-image: _require-maintainer _require-gcloud _image-context
    #!/usr/bin/env bash
    set -euo pipefail
    # Built remotely because Cloud Run is x86_64-only and this is an ARM Mac: a
    # local build must emulate amd64, and the Swift compiler dies under QEMU with
    # SIGILL partway through. Cloud Build is native amd64 — no emulation, no
    # Rosetta, no Docker. Use build-cloud-image-local if you want a local image.
    echo "=== Building {{cloud_service}} on Cloud Build (native linux/amd64) ==="
    # --tag builds AND pushes, so publish-cloud-run needs no separate docker push.
    gcloud builds submit --tag "{{cloud_image}}" .build/image-context
    echo ""
    echo "✓ built and pushed {{cloud_image}}"

# Fallback: build the image locally with Docker instead of on Cloud Build.
[group('publish')]
build-cloud-image-local: _image-context
    #!/usr/bin/env bash
    set -euo pipefail
    # Needs an amd64-capable builder. On Apple Silicon that means Rosetta — under
    # QEMU user-mode emulation the Swift compiler crashes partway through:
    #   softwareupdate --install-rosetta --agree-to-license
    #   colima stop && colima start --vm-type=vz --vz-rosetta --cpu 6 --memory 12
    # Checked up front: without it the failure is a bare 'docker: command not
    # found' from inside the recipe, which says nothing about what to install.
    if ! command -v docker >/dev/null 2>&1; then
        echo "ERROR: docker is not installed, and this recipe builds a linux/amd64 image." >&2
        echo "" >&2
        echo "       Any Docker-compatible runtime will do, e.g." >&2
        echo "         brew install --cask docker        # Docker Desktop" >&2
        echo "         brew install colima docker        # lighter CLI-only alternative" >&2
        echo "" >&2
        echo "       Cloud Run is the only thing that needs this — the npm host and" >&2
        echo "       the local stdio binary build without it." >&2
        exit 1
    fi
    if ! docker info >/dev/null 2>&1; then
        echo "ERROR: docker is installed but the daemon is not running." >&2
        echo "       Start Docker Desktop (or 'colima start'), then re-run." >&2
        exit 1
    fi
    echo "=== Building {{cloud_service}} image for linux/amd64 ==="
    docker build --platform linux/amd64 -t "{{cloud_image}}" .build/image-context
    SIZE=$(docker image inspect "{{cloud_image}}" --format='{{ "{{" }}.Size{{ "}}" }}')
    awk "BEGIN { printf \"  Image: {{cloud_image}}\n  Size:  %.0f MB\n\", $SIZE/1024/1024 }"

# Stage the image's build context: the tracked sources of VGraph with this
# repository inside it, as in a checkout, because Package.swift builds against `..`.
_image-context:
    #!/usr/bin/env bash
    set -euo pipefail
    CTX=.build/image-context
    rm -rf "$CTX"
    mkdir -p "$CTX/VGraph/vgraph-mcp"
    git -C "{{vgraph}}" ls-files -z Package.swift Package.resolved Sources Tests fonts \
        | (cd "{{vgraph}}" && tar --null -cf - -T -) | tar -xf - -C "$CTX/VGraph"
    git ls-files -z Package.swift Package.resolved Sources Tests \
        | tar --null -cf - -T - | tar -xf - -C "$CTX/VGraph/vgraph-mcp"
    cp Dockerfile "$CTX/"

# Build + push the image + roll out a new Cloud Run revision + health check.
[group('publish')]
publish-cloud-run: _require-maintainer _require-vgraph-main _require-gcloud build-cloud-image
    #!/usr/bin/env bash
    set -euo pipefail
    # No push step: `gcloud builds submit --tag` already pushed to Artifact
    # Registry. Building locally instead? Run build-cloud-image-local, then
    # `docker push {{cloud_image}}` yourself before deploying.
    echo "=== Deploying to Cloud Run ==="
    # The service is open to anyone (VGraph's SECURITY.md), so these bound what it can cost.
    # They used to be set by hand with `gcloud run services update`; a fresh deploy
    # would have lost them.
    limits=(
        # --max-instances: one instance caps the bill. The exposure left is
        # availability, which the per-request limits in MCPLimits are for.
        --max-instances=1
        # --concurrency: each render holds a Graphviz layout and, for the PNG, an
        # rsvg-convert process and its bitmap in the instance's 1 GiB. Four in flight
        # peaked at about 440 MB; docs/mcp-hardening.md has the measurements.
        --concurrency=4
        # --timeout: longer than the 120 s request deadline in MCPLimits, so the
        # client gets our 504 and not Cloud Run's.
        --timeout=150
        # --cpu-throttling: CPU only while a request is in flight. Layout is the
        # only work, and idle time then costs nothing.
        --cpu-throttling
    )
    gcloud run deploy "{{cloud_service}}" --image "{{cloud_image}}" --port 8080 --region "{{cloud_region}}" --memory 1Gi "${limits[@]}"
    echo ""
    echo "=== Verifying health check ==="
    curl -s https://mcp.vithanco.com/health
    echo ""
    echo "✓ Cloud Run deploy complete."

# Checked before build-cloud-image runs, so a missing gcloud costs a second
# rather than surfacing after a multi-minute image build.
_require-gcloud:
    #!/usr/bin/env bash
    if ! command -v gcloud >/dev/null 2>&1; then
        echo "ERROR: gcloud is not installed, and both remaining steps need it —" >&2
        echo "       'docker push' to Artifact Registry needs its credential helper," >&2
        echo "       and the deploy is 'gcloud run deploy'." >&2
        echo "" >&2
        echo "         brew install --cask google-cloud-sdk" >&2
        echo "         gcloud auth login && gcloud auth configure-docker" >&2
        exit 1
    fi

# The engine ships from the VGraph checkout around this one: VGraph's own check.
_require-vgraph-main:
    just --justfile "{{vgraph}}/justfile" _require-vgraph-main

# `publish` tags and pushes whatever is checked out here, so it must be main
# with nothing uncommitted beyond the version bump.
_require-main:
    #!/usr/bin/env bash
    set -uo pipefail
    FAIL=0
    BRANCH=$(git branch --show-current)
    if [ "$BRANCH" != main ]; then
        echo "Preflight: vgraph-mcp is on '$BRANCH', not main — publish would tag and push that branch." >&2
        FAIL=1
    fi
    if ! STATUS=$(git status --porcelain -- . ':!package.json' ':!server.json' ':!LICENSE' ':!NOTICE' 2>&1); then
        echo "Preflight: could not read vgraph-mcp's git status: $STATUS" >&2
        FAIL=1
    elif [ -n "$STATUS" ]; then
        echo "Preflight: vgraph-mcp has uncommitted changes besides the version bump:" >&2
        echo "$STATUS" | sed 's/^/  /' >&2
        FAIL=1
    fi
    exit "$FAIL"

_require-maintainer:
    #!/usr/bin/env bash
    if [ "${VITHANCO_MAINTAINER:-}" != "1" ]; then
        echo "This recipe publishes under the Vithanco accounts and is for the maintainer." >&2
        echo "If that is you: export VITHANCO_MAINTAINER=1 in the shell that publishes." >&2
        exit 1
    fi

# Check the tools the publish recipes need. Building needs only VGraph's toolchain.
doctor:
    #!/usr/bin/env bash
    want() { command -v "$1" >/dev/null 2>&1 && echo "  ✅ $1" || echo "  ·  $1 — $2"; }
    echo "Publishing:"
    want npm           "brew install node"
    want gcloud        "the Cloud Run deploy (brew install --cask google-cloud-sdk)"
    want mcp-publisher "the MCP Registry (brew install mcp-publisher)"
    want docker        "only for build-cloud-image-local (brew install colima docker)"
