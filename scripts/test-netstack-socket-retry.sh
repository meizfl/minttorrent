#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${MINTTORRENT_BUILD_ROOT:-$ROOT_DIR/target}"
TEST_BIN="$(mktemp "${TMPDIR:-/tmp}/minttorrent-socket-retry.XXXXXX")"
trap 'rm -f -- "$TEST_BIN"' EXIT

"${CXX:-c++}" -std=c++17 -O2 \
  -DTORRENT_USE_MINTTORRENT_NETSTACK=1 \
  -DTORRENT_USE_OPENSSL -DTORRENT_USE_RTC=0 \
  -I"$ROOT_DIR/vendor/libtorrent/include" \
  -I"$ROOT_DIR/components/awgnet/include" \
  "$ROOT_DIR/tests/netstack_socket_retry.cpp" \
  "$ROOT_DIR/vendor/libtorrent/src/resolver.cpp" \
  "$ROOT_DIR/vendor/libtorrent/src/time.cpp" \
  "$ROOT_DIR/vendor/libtorrent/src/minttorrent_netstack.cpp" \
  -L"$BUILD_ROOT/native/lib" \
  -Wl,-rpath,"$BUILD_ROOT/native/lib" \
  -ltorrent-rasterbar -lminttorrent_awg -pthread -o "$TEST_BIN"

"$TEST_BIN"
echo "PASS: DNS/TCP/UDP fail closed without gVisor; TCP retries and UDP bind/send/async-receive/close use the C++ userspace socket adapters"
