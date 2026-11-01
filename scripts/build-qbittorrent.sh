#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${MINTTORRENT_BUILD_ROOT:-${ROOT_DIR}/target}"
BUILD_DIR="${BUILD_ROOT}/qbittorrent-nox-build"
MINTTORRENT_VERSION="$(tr -d '[:space:]' < "${ROOT_DIR}/VERSION")"
[[ "${MINTTORRENT_VERSION}" =~ ^[0-9A-Za-z][0-9A-Za-z.+-]*$ ]] || {
  echo "Invalid MintTorrent VERSION value: ${MINTTORRENT_VERSION}" >&2
  exit 1
}

cmake -S "${ROOT_DIR}/vendor/qbittorrent" -B "${BUILD_DIR}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="${BUILD_ROOT}/native" \
  -DMINTTORRENT_VERSION="${MINTTORRENT_VERSION}" \
  -DGUI=OFF -DWEBUI=ON -DPLUGINS=ON \
  -DSYSTEMD=OFF -DDBUS=OFF -DSTACKTRACE=OFF -DVERBOSE_CONFIGURE=OFF
cmake --build "${BUILD_DIR}" --parallel "${MINTTORRENT_BUILD_JOBS:-${CMAKE_BUILD_PARALLEL_LEVEL:-4}}"

printf 'Built C++ qBittorrent WebUI/API server: %s\n' "${BUILD_DIR}/qbittorrent-nox"
