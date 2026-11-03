#!/bin/bash
# Build the AuralArchive Docker image (tagged with the version from VERSION).
# A single-architecture build is also exported as a tarball into
# docker_images/ at the repo root (untracked - see .gitignore).
#
# Usage (run it from anywhere; paths are resolved from this file):
#   bash docker/build.sh                                  # host architecture
#   bash docker/build.sh --platform linux/arm64           # Raspberry Pi 5, other arm64 boards
#   bash docker/build.sh --platform linux/amd64,linux/arm64 --push
#                                                         # publish both architectures
#
# Options:
#   -p, --platform <list>  linux/amd64, linux/arm64, or both (default: host arch)
#   -t, --tag <name>       image name to build (default: auralarchive:<version>,
#                          or ghcr.io/auralarchivist/auralarchive:<version> with --push)
#       --push             send the image to the registry instead of saving a tarball
#   A <minor> and a <latest> tag are added automatically for a versioned name.
#
# arm64 notes:
#   - FFmpeg and Python are compiled for the target architecture, so an arm64
#     build on an amd64 machine runs under QEMU emulation and is slow: roughly
#     ten minutes of emulated compile time for FFmpeg and opus on a 28-core
#     machine, and an hour or more on an ordinary laptop. Register the
#     emulator once per boot:
#         docker run --privileged --rm tonistiigi/binfmt --install arm64
#     Faster options: let GitHub Actions build it on a native arm64 runner
#     (.github/workflows/docker-image.yml), or build on the Pi itself.
#   - More than one architecture cannot be exported to a tarball, so a
#     multi-architecture build requires --push (and `docker login` first).
#   - For a Pi without a registry, build one architecture and load the tarball:
#         bash docker/build.sh --platform linux/arm64
#         scp docker_images/*arm64*.tar.gz pi: && ssh pi docker load -i that-file.tar.gz

set -e

usage() {
    # Everything between the shebang and the first blank code line.
    sed -n '2,/^$/{ /^$/d; s/^# \{0,1\}//; p; }' "$0"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGES_DIR="$REPO_ROOT/docker_images"

case "$(uname -m)" in
    x86_64)          HOST_ARCH=amd64 ;;
    aarch64|arm64)   HOST_ARCH=arm64 ;;
    *)               HOST_ARCH="" ;;
esac
# Left empty when the machine's architecture is unknown, so the check below
# can ask for --platform instead of handing "linux/" to Docker.
PLATFORM=$([ -n "$HOST_ARCH" ] && echo "linux/${HOST_ARCH}" || echo "")
PUSH=false
IMAGE_NAME=""
# Default push destination. A fork that publishes its own images should either
# override this with --tag or let the GitHub Actions workflow use its own
# namespace automatically.
REGISTRY_IMAGE="ghcr.io/auralarchivist/auralarchive"

while [ $# -gt 0 ]; do
    case "$1" in
        --platform|-p)
            [ $# -ge 2 ] || { echo "ERROR: $1 needs a value (try: linux/arm64)" >&2; exit 1; }
            PLATFORM="$2"; shift 2 ;;
        --platform=*)  PLATFORM="${1#*=}"; shift ;;
        --push)        PUSH=true; shift ;;
        --tag|-t)
            [ $# -ge 2 ] || { echo "ERROR: $1 needs a value (try: auralarchive:1.0.0)" >&2; exit 1; }
            IMAGE_NAME="$2"; shift 2 ;;
        --tag=*)       IMAGE_NAME="${1#*=}"; shift ;;
        -h|--help)     usage; exit 0 ;;
        -*)            echo "ERROR: unknown option '$1' (see --help)" >&2; exit 1 ;;
        *)             IMAGE_NAME="$1"; shift ;;
    esac
done

export APP_VERSION
APP_VERSION="$(tr -d ' \t\n\r' < "$REPO_ROOT/VERSION")"
if [ -z "$APP_VERSION" ]; then
    echo "ERROR: could not read version from $REPO_ROOT/VERSION" >&2
    exit 1
fi

if [ -z "$HOST_ARCH" ] && [ -z "$PLATFORM" ]; then
    echo "ERROR: cannot tell this machine's architecture from '$(uname -m)'; pass --platform" \
         "(linux/amd64 or linux/arm64)" >&2
    exit 1
fi

# Normalise the platform list: only amd64 and arm64 are supported, spaces are
# tolerated, and duplicates would ask for the same architecture twice.
PLATFORMS=()
for item in $(echo "$PLATFORM" | tr ',' ' '); do
    case "$item" in
        linux/amd64|amd64)          entry=linux/amd64 ;;
        linux/arm64|arm64|aarch64)  entry=linux/arm64 ;;
        "")                         continue ;;
        *)
            echo "ERROR: unsupported platform '$item'" >&2
            echo "       supported: linux/amd64 and linux/arm64 (32-bit ARM is not)" >&2
            exit 1 ;;
    esac
    case " ${PLATFORMS[*]} " in
        *" $entry "*) ;;                        # already listed, skip it
        *) PLATFORMS+=("$entry") ;;
    esac
done

if [ "${#PLATFORMS[@]}" -eq 0 ]; then
    if [ -n "$HOST_ARCH" ]; then
        echo "ERROR: --platform needs a value (this machine is linux/${HOST_ARCH})" >&2
    else
        echo "ERROR: this machine's architecture is not supported; pass --platform" \
             "(linux/amd64 or linux/arm64)" >&2
    fi
    exit 1
fi

# A multi-architecture result has no single-image form, so it can only go to
# a registry, never to a tarball. Rebuild the list into a single value, so
# what Docker is handed is always normalised.
PLATFORM="$(IFS=','; echo "${PLATFORMS[*]}")"
MULTI_ARCH=false
[ "${#PLATFORMS[@]}" -gt 1 ] && MULTI_ARCH=true

if [ -z "$IMAGE_NAME" ]; then
    if [ "$PUSH" = true ]; then
        IMAGE_NAME="$REGISTRY_IMAGE:${APP_VERSION}"
    else
        IMAGE_NAME="auralarchive:${APP_VERSION}"
    fi
fi

BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

docker buildx version >/dev/null 2>&1 || {
    echo "ERROR: docker buildx is required (multi-architecture builds)." >&2
    exit 1
}

# A docker-container builder is needed for multi-arch; the default docker
# driver can only build the host architecture.
BUILDER_ARGS=()
if [ "$MULTI_ARCH" = true ]; then
    BUILDER_ARGS=(--builder auralarchive-multiarch)
    if ! docker buildx inspect auralarchive-multiarch >/dev/null 2>&1; then
        echo "Creating multi-architecture builder 'auralarchive-multiarch'..."
        # No --use: that would leave this builder as the person's default.
        docker buildx create --name auralarchive-multiarch --driver docker-container >/dev/null
    fi
fi

# Split the name into repository and tag. The tag is a colon that appears
# after the last slash, so a registry host with a port (`host:5000/x`) is not
# mistaken for one. An untagged name gets the version.
LAST_ELEMENT="${IMAGE_NAME##*/}"
case "$LAST_ELEMENT" in
    *:*) REPO="${IMAGE_NAME%:*}"; NAME_TAG="${LAST_ELEMENT#*:}" ;;
    *)   REPO="$IMAGE_NAME";     NAME_TAG="$APP_VERSION" ;;
esac

# Add :<minor> and :latest alongside a full version tag, so `:latest` and the
# short version tag keep working as they did before.
TAG_ARGS=(--tag "${REPO}:${NAME_TAG}")
if [ "$NAME_TAG" = "$APP_VERSION" ]; then
    TAG_ARGS+=(--tag "${REPO}:${APP_VERSION%.*}" --tag "${REPO}:latest")
fi

echo "Building for ${PLATFORM} (version ${APP_VERSION})..."
for t in "${TAG_ARGS[@]}"; do [ "$t" = "--tag" ] || echo "  tag: $t"; done
if [ "$PUSH" = true ]; then
    docker buildx build "${BUILDER_ARGS[@]}" \
        --platform "$PLATFORM" \
        --build-arg "APP_VERSION=${APP_VERSION}" \
        --build-arg "BUILD_DATE=${BUILD_DATE}" \
        "${TAG_ARGS[@]}" \
        --provenance=mode=min,inline-only=true \
        --sbom=false \
        --push -f "$SCRIPT_DIR/Dockerfile" "$REPO_ROOT"
    echo "Done. Pushed the manifest list above for: ${PLATFORM}"
    exit 0
fi

if [ "$MULTI_ARCH" = true ]; then
    echo "ERROR: more than one platform cannot be exported to a tarball." >&2
    echo "       Add --push to publish to a registry, or use a single --platform." >&2
    exit 1
fi

mkdir -p "$IMAGES_DIR"
docker buildx build "${BUILDER_ARGS[@]}" \
    --platform "$PLATFORM" \
    --build-arg "APP_VERSION=${APP_VERSION}" \
    --build-arg "BUILD_DATE=${BUILD_DATE}" \
    "${TAG_ARGS[@]}" \
    --load -f "$SCRIPT_DIR/Dockerfile" "$REPO_ROOT"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
SAFE_NAME="${REPO}:${NAME_TAG}"
SAFE_NAME="${SAFE_NAME//[:\/]/_}"
OUTPUT_FILE="$IMAGES_DIR/${SAFE_NAME}-$(echo "$PLATFORM" | tr '/' '-')-${TIMESTAMP}.tar.gz"

# Gzipped: these tarballs are usually copied to a Pi over the network, and
# `docker load` reads a .gz without needing to be told.
echo "Saving image '${REPO}:${NAME_TAG}' to ${OUTPUT_FILE}..."
docker save "${REPO}:${NAME_TAG}" | gzip > "$OUTPUT_FILE"

echo "Done. Image saved to: $OUTPUT_FILE"
echo "Load on the target machine with: docker load -i $(basename "$OUTPUT_FILE")"
echo "(the tarball carries ${REPO}:${NAME_TAG}; the extra tags are local only)"
