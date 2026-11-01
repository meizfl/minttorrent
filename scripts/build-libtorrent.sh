#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${MINTTORRENT_BUILD_ROOT:-${ROOT_DIR}/target}"
BUILD_DIR="${BUILD_ROOT}/libtorrent-build"
INSTALL_DIR="${BUILD_ROOT}/native"

"${ROOT_DIR}/scripts/build-awgnet.sh"

cmake -S "${ROOT_DIR}/vendor/libtorrent" -B "${BUILD_DIR}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
  -Dbuild_tests=OFF \
  -Ddeprecated-functions=OFF \
  -Dpython-bindings=OFF \
  -Dwebtorrent=OFF \
  -Dminttorrent_netstack=ON \
  -DMINTTORRENT_AWG_LIBRARY="${INSTALL_DIR}/lib/libminttorrent_awg.so"

cmake --build "${BUILD_DIR}" --parallel "${MINTTORRENT_BUILD_JOBS:-${CMAKE_BUILD_PARALLEL_LEVEL:-4}}"
cmake --install "${BUILD_DIR}"

printf 'Installed pinned libtorrent to %s\n' "${INSTALL_DIR}"
