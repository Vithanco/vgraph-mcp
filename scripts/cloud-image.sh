#!/usr/bin/env bash
# The hosted server's image, tagged with a hash of the context it is built from,
# so an image with that tag holds exactly these sources and is never built twice.
#
#   scripts/cloud-image.sh tag <context>     # print the tag
#   scripts/cloud-image.sh build <context>   # Cloud Build, unless the image exists
#
# `build` records the tagged image in .build/cloud-image for the deploy. Cloud
# Build takes 8-10 minutes; a resumed publish-all, or a release that changed
# neither the server nor the engine, now skips it. Needs CLOUD_IMAGE (no tag).
set -euo pipefail

REF=.build/cloud-image

tag() { # the paths and contents of every file in the context
    (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256) \
        | shasum -a 256 | cut -c1-16
}

case "${1:-}" in
    tag) tag "$2" ;;
    build)
        TAG=$(tag "$2")
        IMAGE="$CLOUD_IMAGE:$TAG"
        rm -f "$REF"
        # `tags list`, not `images describe`: describe said "not found" for a tag
        # that existed. A failed lookup builds, which is never wrong.
        if gcloud artifacts docker tags list "$CLOUD_IMAGE" --format='value(tag)' 2>/dev/null \
            | grep -xF "$TAG" >/dev/null; then
            echo "· $IMAGE is already built from these sources — skipping Cloud Build"
        else
            # Built remotely because Cloud Run is x86_64-only and this is an ARM
            # Mac: the Swift compiler dies under QEMU emulation. --tag builds and pushes.
            gcloud builds submit --tag "$IMAGE" "$2"
        fi
        mkdir -p "$(dirname "$REF")"
        echo "$IMAGE" > "$REF"
        ;;
    *) echo "usage: $0 tag|build <context>" >&2; exit 2 ;;
esac
