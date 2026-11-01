#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${MINTTORRENT_UBUNTU20_IMAGE:-localhost/minttorrent-builder:ubuntu20}"
BUILD_ROOT="${MINTTORRENT_UBUNTU20_BUILD_ROOT:-$ROOT_DIR/build/ubuntu20-artifacts}"
DIST_ROOT="${MINTTORRENT_UBUNTU20_DIST_DIR:-$ROOT_DIR/build/dist-ubuntu20}"
JOBS="${MINTTORRENT_BUILD_JOBS:-4}"

command -v podman >/dev/null || { echo "podman is required" >&2; exit 1; }
mkdir -p "$BUILD_ROOT" "$DIST_ROOT"

podman build --platform linux/amd64 \
  --file "$ROOT_DIR/containers/ubuntu-20.04.Containerfile" \
  --tag "$IMAGE" "$ROOT_DIR"

podman run --rm --platform linux/amd64 \
  --volume "$ROOT_DIR:/workspace" \
  --env MINTTORRENT_BUILD_ROOT="/workspace/${BUILD_ROOT#"$ROOT_DIR"/}" \
  --env MINTTORRENT_DIST_DIR="/workspace/${DIST_ROOT#"$ROOT_DIR"/}" \
  --env MINTTORRENT_BUILD_JOBS="$JOBS" \
  --env MINTTORRENT_BUILD_TARGET_LABEL="Ubuntu 20.04 (glibc 2.31)" \
  --env MINTTORRENT_BUNDLE_TAG="ubuntu20.04-glibc2.31" \
  --env MINTTORRENT_MAX_GLIBC="2.31" \
  --env GOCACHE="/workspace/${BUILD_ROOT#"$ROOT_DIR"/}/go-cache" \
  --env GOMODCACHE="/workspace/${BUILD_ROOT#"$ROOT_DIR"/}/go-mod-cache" \
  --env LD_LIBRARY_PATH=/opt/minttorrent-deps/lib \
  "$IMAGE" -lc '
    set -euo pipefail
    BUILD_ROOT="$MINTTORRENT_BUILD_ROOT"
    mkdir -p "$BUILD_ROOT"
    if [[ -e "$BUILD_ROOT/native" && ! -L "$BUILD_ROOT/native" ]]; then
      echo "Refusing to replace non-symlink build prefix: $BUILD_ROOT/native" >&2
      exit 1
    fi
    ln -sfn /opt/minttorrent-deps "$BUILD_ROOT/native"
    test "$(getconf GNU_LIBC_VERSION)" = "glibc 2.31"
    cd /workspace
    ./scripts/build-bundle.sh
    archive="$(find "$MINTTORRENT_DIST_DIR" -maxdepth 1 -type f -name "MintTorrent-*-ubuntu20.04-glibc2.31.tar.gz" -print -quit)"
    test -n "$archive"
    tar -tzf "$archive" >/dev/null
    (cd "$MINTTORRENT_DIST_DIR" && sha256sum -c "$(basename "$archive").sha256")
    ./scripts/smoke-bundle.sh "${archive%.tar.gz}"
    MINTTORRENT_INSTALL_TEST_SANDBOX=1 ./scripts/test-install-lifecycle-container.sh "${archive%.tar.gz}"
    echo "Ubuntu 20.04 bundle ready: $archive"
  '
