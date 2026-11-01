#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${MINTTORRENT_BUILD_ROOT:-$ROOT_DIR/target}"
OUTPUT_DIR="$BUILD_ROOT/native/bin"
GOCACHE_DIR="${GOCACHE:-$BUILD_ROOT/go-cache}"
mkdir -p "$OUTPUT_DIR" "$GOCACHE_DIR"
(
  cd "$ROOT_DIR/components/cli"
  CGO_ENABLED=0 GOCACHE="$GOCACHE_DIR" go build \
    -buildvcs=false -trimpath -ldflags='-s -w' \
    -o "$OUTPUT_DIR/minttorrent-cli" .
)
printf 'Built standalone MintTorrent API CLI: %s\n' "$OUTPUT_DIR/minttorrent-cli"
