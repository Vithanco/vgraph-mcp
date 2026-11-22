#!/usr/bin/env bash
# Cloud Build takes 8-10 minutes, and every publish-all paid it again, a resume
# included. An image tagged with its build context's hash is built once.
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
ROOT=$(mktemp -d) || exit 1
trap 'rm -rf "$ROOT"' EXIT
FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }

# gcloud has the tags listed in $WORK/have, and logs every call.
mkdir "$ROOT/bin"
cat > "$ROOT/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$WORK/gcloud.log"
case "$1 $2 $3" in
    # Only `tags list` is trusted: `images describe` said "not found" for a tag that existed.
    "artifacts docker tags") [ "$4 $5" = "list $CLOUD_IMAGE" ] && cat "$WORK/have" 2>/dev/null ;;
    "artifacts docker images") exit 1 ;;
    "builds submit --tag") [ ! -f "$WORK/submit-fails" ] ;;
esac
EOF
chmod +x "$ROOT/bin/gcloud"
export PATH="$ROOT/bin:$PATH" CLOUD_IMAGE=example.invalid/repo/server

given_context() { # a staged build context holding $1
    WORK=$(mktemp -d "$ROOT/work.XXXXXX") || exit 1
    export WORK
    mkdir -p "$WORK/ctx/VGraph/Sources"
    echo "$1" > "$WORK/ctx/VGraph/Sources/engine.swift"
    echo 'FROM swift' > "$WORK/ctx/Dockerfile"
    : > "$WORK/gcloud.log"
}
image() { ( cd "$WORK" && "$REPO_ROOT/scripts/cloud-image.sh" "$@" ) >"$WORK/out" 2>&1; }
submitted() { grep -q '^builds submit' "$WORK/gcloud.log"; }

# Given the same sources twice, then the tag is the same; given other sources, it differs.
given_context a
image tag ctx; A1=$(cat "$WORK/out")
image tag ctx; A2=$(cat "$WORK/out")
given_context b
image tag ctx; B=$(cat "$WORK/out")
[ -n "$A1" ] && [ "$A1" = "$A2" ] || fail "the tag is not stable: '$A1' vs '$A2'"
[ "$A1" != "$B" ] || fail "different sources got the same tag $B"

# Given no image for these sources, when building, then Cloud Build builds it
# under that tag, and deploy is told which image that is.
given_context a
image build ctx || fail "build failed: $(cat "$WORK/out")"
grep -q "^builds submit --tag $CLOUD_IMAGE:$A1 ctx" "$WORK/gcloud.log" || fail "did not submit $A1: $(cat "$WORK/gcloud.log")"
[ "$(cat "$WORK/.build/cloud-image" 2>/dev/null)" = "$CLOUD_IMAGE:$A1" ] || fail "did not record the image for deploy"

# Given the image already built from these sources, when building, then Cloud
# Build is not run, and deploy still gets the image.
given_context a
printf 'latest\n%s\n' "$A1" > "$WORK/have"
image build ctx || fail "build failed: $(cat "$WORK/out")"
submitted && fail "rebuilt an image that exists"
grep -q 'skipping' "$WORK/out" || fail "does not say it skipped: $(cat "$WORK/out")"
[ "$(cat "$WORK/.build/cloud-image" 2>/dev/null)" = "$CLOUD_IMAGE:$A1" ] || fail "did not record the existing image"

# Given Cloud Build fails, then the build fails and no image is recorded for deploy.
given_context a
touch "$WORK/submit-fails"
image build ctx && fail "a failed Cloud Build passed"
[ -f "$WORK/.build/cloud-image" ] && fail "recorded an image that was not built"

[ "$FAILED" -eq 0 ] && echo "✓ cloud-image"
exit "$FAILED"
