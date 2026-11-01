#!/usr/bin/env bash
set -euo pipefail

BUILD_DIR="${1:?usage: test-qbittorrent-host-interface-isolation.sh QBITTORRENT_BUILD_DIR}"
OBJECT="$(find "$BUILD_DIR/src/base/CMakeFiles/qbt_base.dir" \
  -path '*/bittorrent/sessionimpl.cpp.o' -print -quit)"
[[ -n "$OBJECT" && -f "$OBJECT" ]] || {
  echo "qBittorrent sessionimpl object not found under $BUILD_DIR" >&2
  exit 1
}
command -v nm >/dev/null || { echo "nm is required for this isolation check" >&2; exit 1; }

undefined_symbols="$(nm -C -u "$OBJECT")"
if grep -Eq 'QNetworkInterface::(allAddresses|interfaceFromName|interfaceIndexFromName)' \
  <<<"$undefined_symbols"; then
  echo "MintTorrent qBittorrent listener still references host interface enumeration:" >&2
  grep -E 'QNetworkInterface::(allAddresses|interfaceFromName|interfaceIndexFromName)' \
    <<<"$undefined_symbols" >&2
  exit 1
fi

echo "PASS: MintTorrent qBittorrent listener object has no host interface enumeration references."
