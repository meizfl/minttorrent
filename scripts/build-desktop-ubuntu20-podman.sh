#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
IMAGE="${MINTTORRENT_UBUNTU20_IMAGE:-localhost/minttorrent-builder:ubuntu20}"
JOBS="${MINTTORRENT_BUILD_JOBS:-4}"
command -v podman >/dev/null || { echo 'podman is required' >&2; exit 1; }
# Reuse the same Ubuntu 20.04 build kit and caches as the server bundle.
if ! podman image exists "$IMAGE"; then
  podman build --platform linux/amd64 -f "$ROOT/containers/ubuntu-20.04.Containerfile" -t "$IMAGE" "$ROOT"
fi
podman run --rm --platform linux/amd64 \
  --volume "$ROOT:/workspace" \
  --env MINTTORRENT_DESKTOP_BUILD_ROOT=/workspace/build/ubuntu20-artifacts \
  --env MINTTORRENT_DIST_DIR=/workspace/dist \
  --env MINTTORRENT_BUILD_JOBS="$JOBS" \
  --env MINTTORRENT_BUNDLE_TAG=ubuntu20.04-glibc2.31 \
  --env MINTTORRENT_MAX_GLIBC=2.31 \
  --env MINTTORRENT_QT_PLUGINS=/opt/minttorrent-deps/plugins \
  --env GOCACHE=/workspace/build/ubuntu20-artifacts/go-cache \
  --env GOMODCACHE=/workspace/build/ubuntu20-artifacts/go-mod-cache \
  --env LD_LIBRARY_PATH=/opt/minttorrent-deps/lib \
  --env PKG_CONFIG_PATH=/opt/minttorrent-deps/lib/pkgconfig \
  "$IMAGE" -lc '
    set -euo pipefail
    test "$(getconf GNU_LIBC_VERSION)" = "glibc 2.31"
    cd /workspace
    mkdir -p "$MINTTORRENT_DESKTOP_BUILD_ROOT"
    prefix="$MINTTORRENT_DESKTOP_BUILD_ROOT/native"
    if [[ -e "$prefix" && ! -L "$prefix" ]]; then
      echo "Refusing to replace non-symlink build prefix: $prefix" >&2; exit 1
    fi
    ln -sfn /opt/minttorrent-deps "$prefix"
    ./scripts/build-desktop.sh linux
    ./scripts/package-desktop-linux.sh
    name="MintTorrent-$(cat VERSION)-desktop-linux-x86_64-$MINTTORRENT_BUNDLE_TAG"
    stage="$MINTTORRENT_DIST_DIR/$name"
    (cd "$MINTTORRENT_DIST_DIR" && sha256sum -c "$name.tar.gz.sha256")
    (cd "$stage" && sha256sum -c SHA256SUMS > /workspace/build/ubuntu20-desktop-checksums.log)
    python3 scripts/smoke-desktop.py "$stage/MintTorrent"
    bash scripts/test-qbittorrent-host-interface-isolation.sh "$MINTTORRENT_DESKTOP_BUILD_ROOT/qbittorrent"
    probe=/workspace/build/ubuntu20-desktop-gui-probe
    mkdir -p "$probe/profile"
    cmake -S scripts/desktop-gui-probe -B "$probe/build" -G Ninja -DCMAKE_BUILD_TYPE=Release
    cmake --build "$probe/build" --parallel 2
    env -u LD_LIBRARY_PATH QT_QPA_PLATFORM=offscreen LD_PRELOAD="$probe/build/probe.so" \
      MINTTORRENT_GUI_PROBE_DIR="$probe" MINTTORRENT_VPN_AUTOSTART=false \
      timeout 20s "$stage/MintTorrent" --profile="$probe/profile" --confirm-legal-notice
    cat "$probe/result.txt"
    test -s "$probe/main.png"
    echo "Ubuntu 20.04 desktop bundle ready: $stage.tar.gz"
  '
