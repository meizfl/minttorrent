#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${MINTTORRENT_BUILD_ROOT:-${ROOT_DIR}/target}"
OUTPUT_DIR="${BUILD_ROOT}/native/lib"
OUTPUT="${OUTPUT_DIR}/libminttorrent_awg.so"
GO_CACHE_DIR="${GOCACHE:-${BUILD_ROOT}/go-cache}"

mkdir -p "${OUTPUT_DIR}" "${GO_CACHE_DIR}"
(
  cd "${ROOT_DIR}/components/awgnet"
  GOCACHE="${GO_CACHE_DIR}" go build \
    -buildvcs=false \
    -trimpath \
    -buildmode=c-shared \
    -o "${OUTPUT}" .
)

printf 'Built AmneziaWG/gVisor bridge: %s\n' "${OUTPUT}"
