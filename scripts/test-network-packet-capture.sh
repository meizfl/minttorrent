#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if (($# < 2 || $# > 3)); then
  echo "Usage: $0 AWG_PROFILE TORRENT_FILE [STANDALONE_BUNDLE_DIR]" >&2
  exit 2
fi
PROFILE="$(realpath -- "$1")"
TORRENT="$(realpath -- "$2")"
[[ -s "$PROFILE" ]] || { echo "AWG profile is missing or empty" >&2; exit 1; }
[[ -s "$TORRENT" ]] || { echo "Torrent file is missing or empty" >&2; exit 1; }
if (($# == 3)); then
  BUNDLE_DIR="$(cd -- "$3" && pwd)"
elif [[ -x "$ROOT_DIR/bin/minttorrent" ]]; then
  BUNDLE_DIR="$ROOT_DIR"
else
  BUNDLE_DIR="$ROOT_DIR/dist/MintTorrent-$(cat "$ROOT_DIR/VERSION")-$(uname -m)-unknown-linux-gnu"
fi

command -v tcpdump >/dev/null || { echo "tcpdump is required for physical-interface packet capture" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
if ((EUID != 0)); then
  echo "Run this acceptance check as root (or grant tcpdump CAP_NET_RAW and CAP_NET_ADMIN)." >&2
  exit 1
fi

IFS=$'\t' read -r ENDPOINT LOCAL_ADDRESS < <(python3 - "$PROFILE" <<'PY'
import ipaddress
import re
import socket
import sys

peer = False
for line in open(sys.argv[1], encoding='utf-8', errors='replace'):
    value = line.strip()
    if value.startswith('['):
        peer = value.lower() == '[peer]'
    elif peer and value.lower().startswith('endpoint'):
        host_port = value.split('=', 1)[1].strip()
        host, port = host_port.rsplit(':', 1)
        host = host.strip('[]').split('%', 1)[0]
        try:
            address = ipaddress.ip_address(host)
        except ValueError:
            raise SystemExit('AWG Endpoint must be a numeric IP for this packet-capture check')
        family = socket.AF_INET6 if address.version == 6 else socket.AF_INET
        endpoint = (str(address), int(port), 0, 0) if address.version == 6 else (str(address), int(port))
        probe = socket.socket(family, socket.SOCK_DGRAM)
        try:
            probe.connect(endpoint)
            local_address = ipaddress.ip_address(probe.getsockname()[0])
        finally:
            probe.close()
        print(f'{address}\t{local_address}')
        raise SystemExit(0)
raise SystemExit('AWG profile has no [Peer] Endpoint')
PY
)

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/minttorrent-packet-capture.XXXXXX")"
chmod 0700 "$WORK_DIR"
CAPTURE_LOG="$WORK_DIR/tcpdump.log"
CAPTURE_ERR="$WORK_DIR/tcpdump.err"
TEST_LOG="$WORK_DIR/live-test.log"
CAPTURE_PID=""
TEST_PID=""
cleanup() {
  if [[ -n "$TEST_PID" ]]; then
    kill -TERM "$TEST_PID" 2>/dev/null || true
    wait "$TEST_PID" 2>/dev/null || true
  fi
  if [[ -n "$CAPTURE_PID" ]]; then
    kill -INT "$CAPTURE_PID" 2>/dev/null || true
    wait "$CAPTURE_PID" 2>/dev/null || true
  fi
  rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT INT TERM

# Capture only packets transmitted by the host. Torrent protocol packets must
# stay in gVisor; the only allowed public destination is AWG's encrypted peer.
tcpdump -i any -Q out -nn -tt -l 'ip or ip6' >"$CAPTURE_LOG" 2>"$CAPTURE_ERR" &
CAPTURE_PID=$!
sleep 1
kill -0 "$CAPTURE_PID" 2>/dev/null || {
  cat "$CAPTURE_ERR" >&2
  echo "tcpdump could not start an outbound capture" >&2
  exit 1
}

MINTTORRENT_TEST_UDP_RELAY="${MINTTORRENT_TEST_UDP_RELAY:-1}" \
  "$ROOT_DIR/scripts/test-torrent-over-vpn.sh" "$PROFILE" "$TORRENT" "$BUNDLE_DIR" \
  >"$TEST_LOG" 2>&1 &
TEST_PID=$!
if ! wait "$TEST_PID"; then
  TEST_PID=""
  cat "$TEST_LOG" >&2
  echo "Live torrent test failed; packet capture was not accepted." >&2
  exit 1
fi
TEST_PID=""

kill -INT "$CAPTURE_PID" 2>/dev/null || true
wait "$CAPTURE_PID" 2>/dev/null || true
CAPTURE_PID=""

python3 "$ROOT_DIR/scripts/verify-packet-capture.py" "$CAPTURE_LOG" "$ENDPOINT" "$LOCAL_ADDRESS"

cat "$TEST_LOG"
