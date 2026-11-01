#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if (($# < 2 || $# > 3)); then
  echo "Usage: MINTTORRENT_TEST_MAGNET=1 MINTTORRENT_TEST_REQUIRE_UDP_TRACKER=1 MINTTORRENT_TEST_REQUIRE_DHT=1 MINTTORRENT_TEST_REQUIRE_TCP=1 MINTTORRENT_TEST_REQUIRE_UTP=1 MINTTORRENT_TEST_REQUIRE_IPV4=1 MINTTORRENT_TEST_REQUIRE_IPV6=1 MINTTORRENT_TEST_REQUIRE_PEX=1 MINTTORRENT_TEST_BAN_ACTIVE_PEER=1 MINTTORRENT_TEST_UDP_RELAY=1 MINTTORRENT_TEST_AUDIT_NETWORK=1 $0 AWG_PROFILE TORRENT_FILE [BUNDLE_DIR]" >&2
  exit 2
fi
MAGNET_MODE="${MINTTORRENT_TEST_MAGNET:-0}"
[[ "$MAGNET_MODE" == 0 || "$MAGNET_MODE" == 1 ]] || { echo "MINTTORRENT_TEST_MAGNET must be 0 or 1" >&2; exit 2; }
REQUIRE_UDP_TRACKER="${MINTTORRENT_TEST_REQUIRE_UDP_TRACKER:-0}"
[[ "$REQUIRE_UDP_TRACKER" == 0 || "$REQUIRE_UDP_TRACKER" == 1 ]] || { echo "MINTTORRENT_TEST_REQUIRE_UDP_TRACKER must be 0 or 1" >&2; exit 2; }
REQUIRE_DHT="${MINTTORRENT_TEST_REQUIRE_DHT:-0}"
[[ "$REQUIRE_DHT" == 0 || "$REQUIRE_DHT" == 1 ]] || { echo "MINTTORRENT_TEST_REQUIRE_DHT must be 0 or 1" >&2; exit 2; }
RSS_URL="${MINTTORRENT_TEST_RSS_URL:-}"
UDP_RELAY="${MINTTORRENT_TEST_UDP_RELAY:-0}"
[[ "$UDP_RELAY" == 0 || "$UDP_RELAY" == 1 ]] || { echo "MINTTORRENT_TEST_UDP_RELAY must be 0 or 1" >&2; exit 2; }
AUDIT_NETWORK="${MINTTORRENT_TEST_AUDIT_NETWORK:-0}"
[[ "$AUDIT_NETWORK" == 0 || "$AUDIT_NETWORK" == 1 ]] || { echo "MINTTORRENT_TEST_AUDIT_NETWORK must be 0 or 1" >&2; exit 2; }
BENCHMARK_SECONDS="${MINTTORRENT_TEST_BENCHMARK_SECONDS:-0}"
[[ "$BENCHMARK_SECONDS" =~ ^[0-9]+$ ]] || { echo "MINTTORRENT_TEST_BENCHMARK_SECONDS must be a non-negative integer" >&2; exit 2; }
METRICS_CSV="${MINTTORRENT_TEST_METRICS_CSV:-}"
if ((BENCHMARK_SECONDS > 0)) && [[ -z "$METRICS_CSV" ]]; then
  echo "Set MINTTORRENT_TEST_METRICS_CSV to a new output path when benchmarking" >&2
  exit 2
fi
BAN_ACTIVE_PEER="${MINTTORRENT_TEST_BAN_ACTIVE_PEER:-0}"
[[ "$BAN_ACTIVE_PEER" == 0 || "$BAN_ACTIVE_PEER" == 1 ]] || { echo "MINTTORRENT_TEST_BAN_ACTIVE_PEER must be 0 or 1" >&2; exit 2; }
NETSTACK_MTU="${MINTTORRENT_TEST_MTU:-0}"
NETSTACK_PACKET_QUEUE="${MINTTORRENT_TEST_PACKET_QUEUE:-1024}"
NETSTACK_TCP_SEND="${MINTTORRENT_TEST_TCP_SEND_BUFFER:-1048576}"
NETSTACK_TCP_RECEIVE="${MINTTORRENT_TEST_TCP_RECEIVE_BUFFER:-1048576}"
python3 - "$NETSTACK_MTU" "$NETSTACK_PACKET_QUEUE" "$NETSTACK_TCP_SEND" "$NETSTACK_TCP_RECEIVE" <<'PY'
import sys
try: mtu, queue, send, receive = map(int, sys.argv[1:])
except ValueError: raise SystemExit('Netstack test values must be integers')
if mtu != 0 and not 576 <= mtu <= 9000: raise SystemExit('MINTTORRENT_TEST_MTU must be 0 or 576..9000')
if not 64 <= queue <= 16384: raise SystemExit('MINTTORRENT_TEST_PACKET_QUEUE must be 64..16384')
if not 16384 <= send <= 16777216: raise SystemExit('MINTTORRENT_TEST_TCP_SEND_BUFFER must be 16384..16777216')
if not 16384 <= receive <= 16777216: raise SystemExit('MINTTORRENT_TEST_TCP_RECEIVE_BUFFER must be 16384..16777216')
PY
REQUIRE_UTP="${MINTTORRENT_TEST_REQUIRE_UTP:-0}"
[[ "$REQUIRE_UTP" == 0 || "$REQUIRE_UTP" == 1 ]] || { echo "MINTTORRENT_TEST_REQUIRE_UTP must be 0 or 1" >&2; exit 2; }
REQUIRE_TCP="${MINTTORRENT_TEST_REQUIRE_TCP:-0}"
[[ "$REQUIRE_TCP" == 0 || "$REQUIRE_TCP" == 1 ]] || { echo "MINTTORRENT_TEST_REQUIRE_TCP must be 0 or 1" >&2; exit 2; }
REQUIRE_PEX="${MINTTORRENT_TEST_REQUIRE_PEX:-0}"
[[ "$REQUIRE_PEX" == 0 || "$REQUIRE_PEX" == 1 ]] || { echo "MINTTORRENT_TEST_REQUIRE_PEX must be 0 or 1" >&2; exit 2; }
REQUIRE_IPV4="${MINTTORRENT_TEST_REQUIRE_IPV4:-0}"
[[ "$REQUIRE_IPV4" == 0 || "$REQUIRE_IPV4" == 1 ]] || { echo "MINTTORRENT_TEST_REQUIRE_IPV4 must be 0 or 1" >&2; exit 2; }
REQUIRE_IPV6="${MINTTORRENT_TEST_REQUIRE_IPV6:-0}"
[[ "$REQUIRE_IPV6" == 0 || "$REQUIRE_IPV6" == 1 ]] || { echo "MINTTORRENT_TEST_REQUIRE_IPV6 must be 0 or 1" >&2; exit 2; }
[[ "$REQUIRE_UTP" == 0 || "$REQUIRE_TCP" == 0 ]] || { echo "TCP-only and uTP-only modes cannot be combined" >&2; exit 2; }
[[ "$REQUIRE_DHT" == 0 || "$REQUIRE_UDP_TRACKER" == 0 ]] || { echo "DHT-only and UDP-tracker-required modes cannot be combined" >&2; exit 2; }
[[ "$REQUIRE_DHT" == 0 || "$UDP_RELAY" == 0 ]] || { echo "DHT-only mode cannot be combined with the UDP recovery test" >&2; exit 2; }
if [[ "$AUDIT_NETWORK" == 1 ]]; then command -v strace >/dev/null || { echo "strace is required for the network syscall audit" >&2; exit 1; }; fi
PROFILE_SOURCE="$(cd -- "$(dirname -- "$1")" && pwd)/$(basename -- "$1")"
[[ -s "$PROFILE_SOURCE" ]] || { echo "AWG profile is missing or empty" >&2; exit 1; }
TORRENT_SOURCE="$(cd -- "$(dirname -- "$2")" && pwd)/$(basename -- "$2")"
[[ -s "$TORRENT_SOURCE" ]] || { echo "Torrent file is missing or empty" >&2; exit 1; }
if (($# == 3)); then BUNDLE_DIR="$(cd -- "$3" && pwd)"
elif [[ -x "$ROOT_DIR/bin/minttorrent" ]]; then BUNDLE_DIR="$ROOT_DIR"
else BUNDLE_DIR="$ROOT_DIR/dist/MintTorrent-$(cat "$ROOT_DIR/VERSION")-$(uname -m)-unknown-linux-gnu"; fi
LAUNCHER="$BUNDLE_DIR/bin/minttorrent"
[[ -x "$LAUNCHER" ]] || { echo "Bundle launcher not found: $LAUNCHER" >&2; exit 1; }
CLI="$BUNDLE_DIR/bin/minttorrent-cli"
[[ -x "$CLI" ]] || { echo "Bundled MintTorrent CLI not found: $CLI" >&2; exit 1; }
WEBUI_PORT="$(python3 "$ROOT_DIR/scripts/choose-loopback-test-port.py")"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/minttorrent-torrent-vpn.XXXXXX")"
RELAY_PID=""
early_cleanup() {
  if [[ -n "$RELAY_PID" ]]; then kill "$RELAY_PID" 2>/dev/null || true; wait "$RELAY_PID" 2>/dev/null || true; fi
  rm -rf -- "$WORK_DIR"
}
trap early_cleanup EXIT INT TERM
PROFILE="$WORK_DIR/profile"
DOWNLOADS="$WORK_DIR/downloads"
LOG="$WORK_DIR/startup.log"
COOKIE="$WORK_DIR/cookie.txt"
mkdir -m 0700 "$WORK_DIR/source"
cp -- "$PROFILE_SOURCE" "$WORK_DIR/source/awg.conf"
chmod 0600 "$WORK_DIR/source/awg.conf"
RELAY_DROP="$WORK_DIR/relay.drop"
if [[ "$UDP_RELAY" == 1 ]]; then
  RELAY_READY="$WORK_DIR/relay.ready"
  python3 "$ROOT_DIR/scripts/udp-underlay-relay.py" "$WORK_DIR/source/awg.conf" "$RELAY_READY" "$RELAY_DROP" \
    >"$WORK_DIR/relay.log" 2>&1 &
  RELAY_PID=$!
  for _ in {1..100}; do
    [[ -s "$RELAY_READY" ]] && break
    kill -0 "$RELAY_PID" 2>/dev/null || { echo "AWG relay failed to start" >&2; exit 1; }
    sleep 0.1
  done
  [[ -s "$RELAY_READY" ]] || { echo "Timed out waiting for the AWG relay" >&2; exit 1; }
  RELAY_ENDPOINT="$(cat "$RELAY_READY")"
  python3 - "$WORK_DIR/source/awg.conf" "$RELAY_ENDPOINT" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
profile = path.read_text(encoding='utf-8')
updated, count = re.subn(r'(?im)^\s*Endpoint\s*=\s*[^\r\n]+', 'Endpoint = ' + sys.argv[2], profile)
if count != 1:
    raise SystemExit(f'expected one AWG Endpoint line, found {count}')
path.write_text(updated, encoding='utf-8')
path.chmod(0o600)
PY
fi
cp -- "$TORRENT_SOURCE" "$WORK_DIR/test.torrent"
mkdir -p "$DOWNLOADS"

python3 - "$WORK_DIR/test.torrent" "$REQUIRE_DHT" > "$WORK_DIR/torrent-meta.tsv" <<'PY'
import hashlib, sys
from urllib.parse import quote, urlsplit

path = sys.argv[1]
data = open(path, 'rb').read()
def item(i, depth=0):
    if depth > 100: raise ValueError('bencode nesting is too deep')
    t = data[i:i+1]
    if t == b'i':
        j = data.index(b'e', i); return int(data[i+1:j]), j+1
    if t in (b'l', b'd'):
        out = [] if t == b'l' else {}
        i += 1
        while data[i:i+1] != b'e':
            k, i = item(i, depth+1)
            if t == b'd': v, i = item(i, depth+1); out[k] = v
            else: out.append(k)
        return out, i+1
    j = data.index(b':', i); n = int(data[i:j]); j += 1; return data[j:j+n], j+n

root, end = item(0)
if end != len(data) or not isinstance(root, dict) or not isinstance(root.get(b'info'), dict): raise ValueError('invalid torrent metainfo')
def raw_info_span(blob):
    i = 0
    if blob[i:i+1] != b'd': raise ValueError('torrent root is not a dictionary')
    i += 1
    while blob[i:i+1] != b'e':
        key, i = item(i)
        value_start = i
        _, i = item(i)
        if key == b'info': return value_start, i
    raise ValueError('torrent has no info dictionary')

info_start, info_end = raw_info_span(data)
info_bytes = data[info_start:info_end]
if sys.argv[2] == '1':
    for key in (b'announce', b'announce-list', b'url-list', b'url-list.utf-8'):
        root.pop(key, None)
    def encode(value):
        if isinstance(value, bytes): return str(len(value)).encode() + b':' + value
        if isinstance(value, int): return b'i' + str(value).encode() + b'e'
        if isinstance(value, list): return b'l' + b''.join(encode(v) for v in value) + b'e'
        if isinstance(value, dict):
            out = bytearray(b'd')
            for key in sorted(value):
                out.extend(encode(key))
                out.extend(info_bytes if key == b'info' else encode(value[key]))
            out.extend(b'e')
            return bytes(out)
        raise TypeError(f'unsupported bencode value {type(value).__name__}')
    data = encode(root)
    open(path, 'wb').write(data)
    root, end = item(0)
    if end != len(data): raise ValueError('internal error rewriting trackerless torrent')
    info_start, info_end = raw_info_span(data)
    if data[info_start:info_end] != info_bytes: raise ValueError('DHT test rewrite changed the info dictionary')
info = root[b'info']
urls = [root.get(b'announce')] + [url for tier in root.get(b'announce-list', []) for url in tier]
urls = list(dict.fromkeys(url for url in urls if url))
hosts = sorted({urlsplit(u.decode('utf-8', 'replace')).hostname or '' for u in urls})
udp_hosts = sorted({urlsplit(u.decode('utf-8', 'replace')).hostname or '' for u in urls
                    if urlsplit(u.decode('utf-8', 'replace')).scheme.lower() == 'udp'})
info_hash = hashlib.sha1(data[info_start:info_end]).hexdigest()
if sys.argv[2] == '1' and (urls or b'url-list' in root or b'url-list.utf-8' in root):
    raise ValueError('DHT-only test metainfo still contains trackers or web seeds')
magnet = 'magnet:?xt=urn:btih:' + info_hash
magnet += ''.join('&tr=' + quote(url.decode('utf-8'), safe='') for url in urls)
print(info_hash, ','.join(hosts), magnet, ','.join(udp_hosts), sep='\t')
PY
IFS=$'\t' read -r INFO_HASH TRACKER_HOSTS MAGNET_URI UDP_TRACKER_HOSTS < "$WORK_DIR/torrent-meta.tsv"
if [[ "$REQUIRE_UDP_TRACKER" == 1 && -z "$UDP_TRACKER_HOSTS" ]]; then
  echo "UDP tracker success was required, but the supplied torrent has no UDP tracker" >&2
  exit 1
fi
cat > "$WORK_DIR/config.toml" <<CONFIG
[vpn]
config = "$WORK_DIR/source/awg.conf"
autostart = true
[torrent]
webui_port = $WEBUI_PORT
listen_port = 0
[torrent.storage]
download_path = "$DOWNLOADS"
CONFIG

export MINTTORRENT_PROFILE="$PROFILE" MINTTORRENT_CONFIG="$WORK_DIR/config.toml"
if [[ "$REQUIRE_DHT" == 1 ]]; then export MINTTORRENT_DHT_TRACE=1; fi
if [[ "$AUDIT_NETWORK" == 1 ]]; then
  TRACE="$WORK_DIR/network.trace"
  strace -f -qq -e trace=network -o "$TRACE" "$LAUNCHER" >"$LOG" 2>&1 &
else
  "$LAUNCHER" >"$LOG" 2>&1 &
fi
PID=$!
stop_profile_instance() {
  python3 - "$PROFILE" <<'PY'
import os, signal, sys
profile = os.path.realpath(sys.argv[1])
for entry in os.listdir('/proc'):
    if not entry.isdigit(): continue
    try: args = open(f'/proc/{entry}/cmdline', 'rb').read().split(b'\0')
    except OSError: continue
    if not args or not args[0].endswith(b'/qbittorrent-nox'): continue
    paths = [a.split(b'=', 1)[1].decode(errors='replace') for a in args if a.startswith(b'--profile=')]
    if any(os.path.realpath(p) == profile for p in paths):
        try: os.kill(int(entry), signal.SIGTERM)
        except ProcessLookupError: pass
PY
  for _ in {1..100}; do
    if ! kill -0 "$PID" 2>/dev/null; then return; fi
    sleep 0.1
  done
  kill -KILL "$PID" 2>/dev/null || true
}
cleanup() {
  stop_profile_instance
  wait "$PID" 2>/dev/null || true
  if [[ -n "$RELAY_PID" ]]; then kill "$RELAY_PID" 2>/dev/null || true; wait "$RELAY_PID" 2>/dev/null || true; fi
  rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT INT TERM

BASE="http://127.0.0.1:$WEBUI_PORT"
for _ in {1..30}; do
  code="$(curl --noproxy '*' --connect-timeout 1 -sS -o /dev/null -w '%{http_code}' "$BASE/" 2>/dev/null || true)"
  [[ "$code" == 200 ]] && break
  kill -0 "$PID" 2>/dev/null || { echo "MintTorrent exited during startup; check config and AWG profile" >&2; exit 1; }
  sleep 1
done
[[ "${code:-}" == 200 ]] || { echo "WebUI failed on loopback port $WEBUI_PORT" >&2; exit 1; }
password="$(sed -nE '/temporary password|тимчасовий пароль/Is/.*: ([[:alnum:]]+).*/\1/p' "$LOG" | tail -n1)"
[[ -n "$password" ]] || { echo "First-run WebUI password was not emitted" >&2; exit 1; }
login="$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' -c "$COOKIE" \
  --data-urlencode username=admin --data-urlencode "password=$password" "$BASE/api/v2/auth/login")"
[[ "$login" == 200 || "$login" == 204 ]] || { echo "WebUI login failed" >&2; exit 1; }

PROTOCOL_ID=0
if [[ "$REQUIRE_UTP" == 1 ]]; then PROTOCOL_ID=2; fi
if [[ "$REQUIRE_TCP" == 1 ]]; then PROTOCOL_ID=1; fi
PREFS_JSON="{\"bittorrent_protocol\":$PROTOCOL_ID,\"pex\":true}"
curl --noproxy '*' -fsS -b "$COOKIE" -X POST --data-urlencode "json=$PREFS_JSON" \
  "$BASE/api/v2/app/setPreferences" >/dev/null
curl --noproxy '*' -fsS -b "$COOKIE" "$BASE/api/v2/app/preferences" > "$WORK_DIR/preferences.json"
python3 - "$WORK_DIR/preferences.json" "$PROTOCOL_ID" <<'PY'
import json, sys
prefs = json.load(open(sys.argv[1], encoding='utf-8'))
assert int(prefs.get('bittorrent_protocol', -1)) == int(sys.argv[2]), 'peer protocol preference was not applied'
assert prefs.get('pex') is True, 'PeX preference was not enabled'
PY

vpn_ready=0
for attempt in {1..60}; do
  curl --noproxy '*' -fsS -b "$COOKIE" "$BASE/api/v2/app/minttorrentVpnStatus" > "$WORK_DIR/vpn.json"
  if python3 - "$WORK_DIR/vpn.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1], encoding='utf-8'))
raise SystemExit(0 if s.get('enabled') and s.get('active') and s.get('data_path_healthy') and s.get('last_handshake_ns') else 1)
PY
  then vpn_ready=1; break; fi
  if ((attempt % 10 == 0)); then echo "Waiting for healthy AWG handshake (${attempt} s)..."; fi
  sleep 1
done
((vpn_ready == 1)) || { echo "AWG did not become healthy before torrent test" >&2; exit 1; }
# Force a controlled endpoint outage in the isolated profile, prove that the
# health state turns unhealthy, then restore the original endpoint before any
# torrent is added. The dead endpoint is loopback-only and cannot send traffic
# to an external host interface. This exercises failure detection and recovery
# through the same authenticated API used by the settings tab.
python3 - "$WORK_DIR/source/awg.conf" "$WORK_DIR/endpoint-down.conf" <<'PY'
import pathlib, re, sys
source = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
updated, count = re.subn(r'(?im)^\s*Endpoint\s*=\s*[^\r\n]+', 'Endpoint = 127.0.0.1:9', source)
if count != 1:
    raise SystemExit(f'expected exactly one numeric AWG Endpoint line, found {count}')
pathlib.Path(sys.argv[2]).write_text(updated, encoding='utf-8')
PY
import_vpn_profile() {
  curl --noproxy '*' -fsS -b "$COOKIE" -X POST \
    --data-urlencode "profile@$1" \
    --data-urlencode ipv4=true --data-urlencode ipv6=true \
    --data-urlencode "mtu=$NETSTACK_MTU" --data-urlencode "packet_queue=$NETSTACK_PACKET_QUEUE" \
    --data-urlencode "tcp_send_buffer=$NETSTACK_TCP_SEND" --data-urlencode "tcp_receive_buffer=$NETSTACK_TCP_RECEIVE" \
    "$BASE/api/v2/app/minttorrentVpnImport" >/dev/null
}
import_vpn_profile "$WORK_DIR/endpoint-down.conf"
outage_detected=0
for attempt in {1..60}; do
  curl --noproxy '*' -fsS -b "$COOKIE" "$BASE/api/v2/app/minttorrentVpnStatus" > "$WORK_DIR/vpn.json" || true
  if python3 - "$WORK_DIR/vpn.json" <<'PY'
import json, sys
try: s = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception: raise SystemExit(1)
raise SystemExit(0 if s.get('active') and not s.get('data_path_healthy') else 1)
PY
  then outage_detected=1; break; fi
  sleep 1
done
if ((outage_detected != 1)); then
  echo "VPN did not report an unhealthy data path with its loopback-only test endpoint" >&2
  exit 1
fi
import_vpn_profile "$WORK_DIR/source/awg.conf"
recovered=0
for attempt in {1..120}; do
  curl --noproxy '*' -fsS -b "$COOKIE" "$BASE/api/v2/app/minttorrentVpnStatus" > "$WORK_DIR/vpn.json" || true
  if python3 - "$WORK_DIR/vpn.json" <<'PY'
import json, sys
try: s = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception: raise SystemExit(1)
raise SystemExit(0 if s.get('enabled') and s.get('active') and s.get('data_path_healthy') and s.get('last_handshake_ns') else 1)
PY
  then recovered=1; break; fi
  sleep 1
done
((recovered == 1)) || { echo "VPN data path did not recover after restoring the original profile" >&2; exit 1; }
curl --noproxy '*' -fsS -b "$COOKIE" "$BASE/api/v2/app/minttorrentVpnStatus" > "$WORK_DIR/vpn-netstack-settings.json"
python3 - "$WORK_DIR/vpn-netstack-settings.json" "$NETSTACK_MTU" "$NETSTACK_PACKET_QUEUE" "$NETSTACK_TCP_SEND" "$NETSTACK_TCP_RECEIVE" <<'PY'
import json, sys
status = json.load(open(sys.argv[1], encoding='utf-8'))
expected = dict(zip(('mtu', 'packet_queue', 'tcp_send_buffer', 'tcp_receive_buffer'), map(int, sys.argv[2:])))
actual = {key: int(status.get(key, -1)) for key in expected}
assert actual == expected, (actual, expected)
assert status.get('data_path_healthy') and status.get('last_handshake_ns'), status
PY
echo "PASS: VPN recovered through the settings API with gVisor mtu=$NETSTACK_MTU, packet_queue=$NETSTACK_PACKET_QUEUE, tcp_send_buffer=$NETSTACK_TCP_SEND, tcp_receive_buffer=$NETSTACK_TCP_RECEIVE."
# Exercise the same enable/disable actions used by the settings tab before
# testing torrent traffic. This also verifies libtorrent reopens its listeners
# against the newly active gVisor interface after a VPN restart.
curl --noproxy '*' -fsS -b "$COOKIE" -X POST --data-urlencode enabled=false \
  "$BASE/api/v2/app/minttorrentVpnSet" >/dev/null
disabled=0
for attempt in {1..30}; do
  curl --noproxy '*' -fsS -b "$COOKIE" "$BASE/api/v2/app/minttorrentVpnStatus" > "$WORK_DIR/vpn.json" || true
  if python3 - "$WORK_DIR/vpn.json" <<'PY'
import json, sys
try: s = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception: raise SystemExit(1)
raise SystemExit(0 if not s.get('enabled') and not s.get('active') else 1)
PY
  then disabled=1; break; fi
  sleep 1
done
((disabled == 1)) || { echo "WebUI VPN disconnect did not stop the userspace stack" >&2; exit 1; }
curl --noproxy '*' -fsS -b "$COOKIE" -X POST --data-urlencode enabled=true \
  "$BASE/api/v2/app/minttorrentVpnSet" >/dev/null
reconnected=0
for attempt in {1..120}; do
  curl --noproxy '*' -fsS -b "$COOKIE" "$BASE/api/v2/app/minttorrentVpnStatus" > "$WORK_DIR/vpn.json" || true
  if python3 - "$WORK_DIR/vpn.json" <<'PY'
import json, sys
try: s = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception: raise SystemExit(1)
raise SystemExit(0 if s.get('enabled') and s.get('active') and s.get('data_path_healthy') and s.get('last_handshake_ns') else 1)
PY
  then reconnected=1; break; fi
  sleep 1
done
((reconnected == 1)) || { echo "WebUI VPN reconnect failed the handshake or gVisor data-path health check" >&2; exit 1; }

if [[ -n "$RSS_URL" ]]; then
  RSS_PATH="MintTorrent-RSS-smoke"
  curl --noproxy '*' -fsS -b "$COOKIE" -X POST \
    --data-urlencode "url=$RSS_URL" --data-urlencode "path=$RSS_PATH" --data-urlencode refreshInterval=0 \
    "$BASE/api/v2/rss/addFeed" > /dev/null
  curl --noproxy '*' -fsS -b "$COOKIE" -X POST --data-urlencode "itemPath=$RSS_PATH" \
    "$BASE/api/v2/rss/refreshItem" > /dev/null
  rss_ready=0
  for attempt in {1..120}; do
    curl --noproxy '*' -fsS -b "$COOKIE" --get --data-urlencode withData=true \
      "$BASE/api/v2/rss/items" > "$WORK_DIR/rss-items.json"
    if python3 - "$WORK_DIR/rss-items.json" "$RSS_URL" <<'PY'
import json, sys
def find_feed(node, url):
    if isinstance(node, dict):
        if node.get('url') and node.get('articles') is not None:
            if node.get('url') == url:
                return node
        for value in node.values():
            found = find_feed(value, url)
            if found:
                return found
    elif isinstance(node, list):
        for value in node:
            found = find_feed(value, url)
            if found:
                return found
    return None
feed = find_feed(json.load(open(sys.argv[1], encoding='utf-8')), sys.argv[2])
raise SystemExit(0 if feed and feed.get('articles') and not feed.get('hasError') else 1)
PY
    then rss_ready=1; break; fi
    if ((attempt % 20 == 0)); then echo "Waiting for RSS refresh through gVisor (${attempt} s)..."; fi
    sleep 1
  done
  ((rss_ready == 1)) || { echo "RSS did not return parsed articles through the active gVisor stack" >&2; exit 1; }
  curl --noproxy '*' -fsS -b "$COOKIE" -X POST --data-urlencode "path=$RSS_PATH" \
    "$BASE/api/v2/rss/removeItem" > /dev/null
  echo "PASS: RSS feed fetched and parsed through the active gVisor userspace stack."
fi

if [[ "$MAGNET_MODE" == 1 ]]; then
  MINTTORRENT_WEBUI_URL="$BASE" MINTTORRENT_WEBUI_USERNAME=admin MINTTORRENT_WEBUI_PASSWORD="$password" \
    "$CLI" torrent add "$MAGNET_URI" >/dev/null
  TEST_SOURCE=magnet
else
  MINTTORRENT_WEBUI_URL="$BASE" MINTTORRENT_WEBUI_USERNAME=admin MINTTORRENT_WEBUI_PASSWORD="$password" \
    "$CLI" torrent add "$WORK_DIR/test.torrent" >/dev/null
  TEST_SOURCE=torrent-file
fi

success=0
DISCOVERY_TIMEOUT=180
if [[ "$REQUIRE_UTP" == 1 || "$REQUIRE_TCP" == 1 || "$REQUIRE_PEX" == 1 || "$REQUIRE_IPV4" == 1 || "$REQUIRE_IPV6" == 1 ]]; then DISCOVERY_TIMEOUT=300; fi
for ((attempt = 1; attempt <= DISCOVERY_TIMEOUT; ++attempt)); do
  kill -0 "$PID" 2>/dev/null || { echo "qBittorrent exited during the torrent network test" >&2; exit 1; }
  curl --noproxy '*' -fsS -b "$COOKIE" "$BASE/api/v2/torrents/trackers?hash=$INFO_HASH" > "$WORK_DIR/trackers.json" || true
  curl --noproxy '*' -fsS -b "$COOKIE" "$BASE/api/v2/torrents/info?hash=$INFO_HASH" > "$WORK_DIR/torrent.json" || true
  curl --noproxy '*' -fsS -b "$COOKIE" "$BASE/api/v2/torrents/properties?hash=$INFO_HASH" > "$WORK_DIR/properties.json" || true
  curl --noproxy '*' -fsS -b "$COOKIE" "$BASE/api/v2/sync/torrentPeers?hash=$INFO_HASH&rid=0" > "$WORK_DIR/peers.json" || true
  if [[ "$REQUIRE_DHT" == 1 ]]; then
    curl --noproxy '*' -fsS -b "$COOKIE" "$BASE/api/v2/sync/maindata?rid=0" > "$WORK_DIR/maindata.json" || true
    curl --noproxy '*' -fsS -b "$COOKIE" "$BASE/api/v2/transfer/info" > "$WORK_DIR/transfer.json" || true
  fi
  if python3 - "$WORK_DIR/trackers.json" "$WORK_DIR/torrent.json" "$WORK_DIR/properties.json" "$TRACKER_HOSTS" "$UDP_TRACKER_HOSTS" "$REQUIRE_UDP_TRACKER" "$WORK_DIR/maindata.json" "$WORK_DIR/peers.json" "$REQUIRE_DHT" "$REQUIRE_UTP" "$REQUIRE_PEX" "$REQUIRE_TCP" "$REQUIRE_IPV4" "$REQUIRE_IPV6" <<'PY'
import json, sys
from urllib.parse import urlsplit
try: rows = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception: raise SystemExit(1)
try: torrent = json.load(open(sys.argv[2], encoding='utf-8'))[0]
except Exception: raise SystemExit(1)
try: properties = json.load(open(sys.argv[3], encoding='utf-8'))
except Exception: raise SystemExit(1)
hosts = set(filter(None, sys.argv[4].split(',')))
udp_hosts = set(filter(None, sys.argv[5].split(',')))
tracker_ok = any(any(host in row.get('url', '') for host in hosts) and row.get('status') == 2 for row in rows)
udp_tracker_ok = any(row.get('status') == 2 and urlsplit(row.get('url', '')).scheme.lower() == 'udp'
                     and urlsplit(row.get('url', '')).hostname in udp_hosts for row in rows)
downloaded = torrent.get('downloaded', 0)
udp_required = sys.argv[6] == '1'
dht_ok = False
if sys.argv[9] == '1':
    try: maindata = json.load(open(sys.argv[7], encoding='utf-8'))
    except Exception: maindata = {}
    try: peer_data = json.load(open(sys.argv[8], encoding='utf-8'))
    except Exception: peer_data = {}
    dht_nodes = maindata.get('server_state', {}).get('dht_nodes', 0)
    peer_count = len(peer_data.get('peers', {}))
    dht_ok = dht_nodes > 0 and peer_count > 0
tracker_required = sys.argv[9] != '1'
try: peers = json.load(open(sys.argv[8], encoding='utf-8')).get('peers', {})
except Exception: peers = {}
peer_transports = {str(peer.get('connection', '')).lower().replace('μ', 'u').replace('µ', 'u') for peer in peers.values()}
utp_ok = any('utp' in transport for transport in peer_transports)
tcp_ok = 'bt' in peer_transports
import ipaddress
payload_families = set()
for peer in peers.values():
    try:
        if int(peer.get('downloaded', 0)) <= 0: continue
        transport = str(peer.get('connection', '')).lower().replace('μ', 'u').replace('µ', 'u')
        if transport != 'bt' and 'utp' not in transport: continue
        payload_families.add(ipaddress.ip_address(peer.get('ip', '')).version)
    except (ValueError, TypeError):
        continue
pex_ok = any(row.get('url') == '** [PeX] **' and
             (int(row.get('num_seeds', 0)) > 0 or int(row.get('num_leeches', 0)) > 0)
             for row in rows)
raise SystemExit(0 if (tracker_ok or not tracker_required) and (udp_tracker_ok or not udp_required)
                 and (dht_ok or sys.argv[9] != '1') and (utp_ok or sys.argv[10] != '1')
                 and (pex_ok or sys.argv[11] != '1') and (tcp_ok or sys.argv[12] != '1')
                 and (4 in payload_families or sys.argv[13] != '1')
                 and (6 in payload_families or sys.argv[14] != '1') and downloaded > 0
                 and torrent.get('progress', 0) > 0 and properties.get('pieces_have', 0) > 0 else 1)
PY
  then success=1; break; fi
  if (( attempt % 15 == 0 )); then
    if [[ "$REQUIRE_DHT" == 1 ]]; then
      echo "Waiting for DHT bootstrap, a peer, and a verified piece through VPN (${attempt} s)..."
    elif [[ "$REQUIRE_UTP" == 1 ]]; then
      echo "Waiting for a uTP peer and a verified piece through VPN (${attempt} s)..."
    elif [[ "$REQUIRE_TCP" == 1 ]]; then
      echo "Waiting for a TCP peer and a verified piece through VPN (${attempt} s)..."
    elif [[ "$REQUIRE_PEX" == 1 ]]; then
      echo "Waiting for PeX-discovered peers and a verified piece through VPN (${attempt} s)..."
    else
      echo "Waiting for tracker announce and a verified piece through VPN (${attempt} s)..."
    fi
  fi
  sleep 1
done
if ((success == 0)); then
  if [[ "$REQUIRE_DHT" == 1 ]]; then
    curl --noproxy '*' -fsS -b "$COOKIE" "$BASE/api/v2/app/preferences" > "$WORK_DIR/preferences.json" || true
    curl --noproxy '*' -fsS -b "$COOKIE" "$BASE/api/v2/log/main?normal=true&info=true&warning=true&critical=true" > "$WORK_DIR/main-log.json" || true
    curl --noproxy '*' -fsS -b "$COOKIE" "$BASE/api/v2/transfer/info" > "$WORK_DIR/transfer.json" || true
    python3 - "$WORK_DIR/preferences.json" "$WORK_DIR/main-log.json" "$WORK_DIR/transfer.json" >&2 <<'PY'
import json, re, sys
try: prefs = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception: prefs = {}
print(f"DHT enabled={prefs.get('dht')} bootstrap_nodes={prefs.get('dht_bootstrap_nodes')}")
try: counters = json.load(open(sys.argv[3], encoding='utf-8'))
except Exception: counters = {}
print("DHT counters: " + ", ".join(f"{key}={counters.get(key, 'unavailable')}" for key in (
    'minttorrent_dht_bytes_out', 'minttorrent_dht_bytes_in',
    'minttorrent_dht_rate_out', 'minttorrent_dht_rate_in',
    'minttorrent_dht_messages_out', 'minttorrent_dht_messages_in',
    'minttorrent_dht_messages_in_dropped', 'dht_nodes')))
try: rows = json.load(open(sys.argv[2], encoding='utf-8'))
except Exception: rows = []
for row in rows:
    message = str(row.get('message', ''))
    if re.search(r'dht|bootstrap|router|name lookup|resolve', message, re.I):
        print(f"DHT log [{row.get('type', '?')}]: {message[:500]}")
PY
  fi
  if [[ -s "$LOG" ]]; then
    echo "Userspace transport diagnostics:" >&2
    rg 'MintTorrent userspace (TCP connect|UDP send) failed:' "$LOG" | tail -n 20 >&2 || true
  fi
  python3 - "$WORK_DIR/trackers.json" "$WORK_DIR/torrent.json" "$WORK_DIR/properties.json" "$TRACKER_HOSTS" >&2 <<'PY'
import json, sys
hosts = set(filter(None, sys.argv[4].split(',')))
try:
    rows = json.load(open(sys.argv[1], encoding='utf-8'))
    for row in rows:
        if any(host in row.get('url', '') for host in hosts):
            print(f"tracker status={row.get('status')} message={row.get('msg')}")
except Exception: pass
try:
    torrent = json.load(open(sys.argv[2], encoding='utf-8'))[0]
    print(f"torrent progress={torrent.get('progress')} downloaded={torrent.get('downloaded')} seeds={torrent.get('num_seeds')} peers={torrent.get('num_leechs')}")
except Exception: pass
try:
    properties = json.load(open(sys.argv[3], encoding='utf-8'))
    print(f"verified pieces={properties.get('pieces_have')}")
except Exception: pass
PY
  if [[ "$REQUIRE_DHT" == 1 ]]; then
    python3 - "$WORK_DIR/maindata.json" "$WORK_DIR/peers.json" "$WORK_DIR/transfer.json" >&2 <<'PY'
import json, sys
try: state = json.load(open(sys.argv[1], encoding='utf-8')).get('server_state', {})
except Exception: state = {}
try: peers = json.load(open(sys.argv[2], encoding='utf-8')).get('peers', {})
except Exception: peers = {}
print(f"DHT nodes={state.get('dht_nodes', 0)} peer connections={len(peers)} peer transports={sorted({p.get('connection', '?') for p in peers.values()})}")
try: counters = json.load(open(sys.argv[3], encoding='utf-8'))
except Exception: counters = {}
print("DHT counters: " + ", ".join(f"{key}={counters.get(key, 'unavailable')}" for key in (
    'minttorrent_dht_bytes_out', 'minttorrent_dht_bytes_in',
    'minttorrent_dht_rate_out', 'minttorrent_dht_rate_in',
    'minttorrent_dht_messages_out', 'minttorrent_dht_messages_in',
    'minttorrent_dht_messages_in_dropped')))
PY
    echo "DHT-only torrent did not discover a peer and download a verified piece through the isolated VPN session." >&2
  elif [[ "$REQUIRE_UTP" == 1 || "$REQUIRE_TCP" == 1 || "$REQUIRE_PEX" == 1 || "$REQUIRE_IPV4" == 1 || "$REQUIRE_IPV6" == 1 ]]; then
    python3 - "$WORK_DIR/peers.json" "$WORK_DIR/trackers.json" <<'PY'
import ipaddress, json, sys
try: peers = json.load(open(sys.argv[1], encoding='utf-8')).get('peers', {})
except Exception: peers = {}
try: rows = json.load(open(sys.argv[2], encoding='utf-8'))
except Exception: rows = []
print(f"Peer transports observed={sorted({p.get('connection', '?') for p in peers.values()})}")
pex = next((r for r in rows if r.get('url') == '** [PeX] **'), {})
print(f"Peers reported via PeX={int(pex.get('num_seeds', 0)) + int(pex.get('num_leeches', 0))}")
families = set()
for peer in peers.values():
    try:
        transport = str(peer.get('connection', '')).lower().replace('μ', 'u').replace('µ', 'u')
        if int(peer.get('downloaded', 0)) > 0 and (transport == 'bt' or 'utp' in transport):
            families.add(ipaddress.ip_address(peer.get('ip', '')).version)
    except (ValueError, TypeError):
        continue
print(f"Peer payload families={sorted(families)}")
PY
    echo "Required peer transport/extension was not observed with a verified torrent piece." >&2
  elif [[ "$REQUIRE_UDP_TRACKER" == 1 ]]; then
    echo "No successful UDP tracker announce and verified piece download observed through the isolated VPN torrent session." >&2
  else
    echo "No successful announce and piece download observed through the isolated VPN torrent session." >&2
  fi
  exit 1
fi

if [[ "$BAN_ACTIVE_PEER" == 1 ]]; then
  curl --noproxy '*' -fsS -b "$COOKIE" \
    "$BASE/api/v2/sync/torrentPeers?hash=$INFO_HASH&rid=0" > "$WORK_DIR/peers-before-ban.json"
  python3 - "$WORK_DIR/peers-before-ban.json" "$WORK_DIR/peer-to-ban.json" <<'PY'
import ipaddress, json, sys
peers = json.load(open(sys.argv[1], encoding='utf-8')).get('peers', {})
candidate = None
for peer in peers.values():
    try:
        ip = ipaddress.ip_address(peer['ip'])
        if int(peer.get('downloaded', 0)) <= 0 and int(peer.get('uploaded', 0)) <= 0:
            continue
        endpoint = f'[{ip}]:{int(peer["port"])}' if ip.version == 6 else f'{ip}:{int(peer["port"])}'
        candidate = {'ip': str(ip), 'endpoint': endpoint}
        break
    except (KeyError, ValueError, TypeError):
        continue
if candidate is None:
    raise SystemExit('no active payload-carrying peer is available to ban')
json.dump(candidate, open(sys.argv[2], 'w', encoding='utf-8'))
PY
  read -r peer_ip peer_endpoint < <(python3 - "$WORK_DIR/peer-to-ban.json" <<'PY'
import json, sys
peer = json.load(open(sys.argv[1], encoding='utf-8'))
print(peer['ip'], peer['endpoint'])
PY
)
  curl --noproxy '*' -fsS -b "$COOKIE" -X POST --data-urlencode "peers=$peer_endpoint" \
    "$BASE/api/v2/transfer/banPeers" > /dev/null
  curl --noproxy '*' -fsS -b "$COOKIE" "$BASE/api/v2/app/preferences" > "$WORK_DIR/preferences-after-peer-ban.json"
  python3 - "$WORK_DIR/preferences-after-peer-ban.json" "$peer_ip" <<'PY'
import json, sys
preferences = json.load(open(sys.argv[1], encoding='utf-8'))
assert sys.argv[2] in preferences.get('banned_IPs', '').splitlines(), preferences.get('banned_IPs')
PY
  peer_closed=0
  for attempt in {1..15}; do
    curl --noproxy '*' -fsS -b "$COOKIE" \
      "$BASE/api/v2/sync/torrentPeers?hash=$INFO_HASH&rid=0" > "$WORK_DIR/peers-after-ban.json"
    if python3 - "$WORK_DIR/peers-after-ban.json" "$peer_ip" <<'PY'
import json, sys
peers = json.load(open(sys.argv[1], encoding='utf-8')).get('peers', {}).values()
raise SystemExit(0 if all(peer.get('ip') != sys.argv[2] for peer in peers) else 1)
PY
    then peer_closed=1; break; fi
    sleep 1
  done
  ((peer_closed == 1)) || { echo "Banned active peer remained connected" >&2; exit 1; }
  echo "PASS: transfer/banPeers added an active payload-carrying peer to the temporary IP filter and closed its connection."
fi

if ((BENCHMARK_SECONDS > 0)); then
  python3 "$ROOT_DIR/scripts/sample-qbittorrent-metrics.py" \
    --url "$BASE" --cookie "$COOKIE" --hash "$INFO_HASH" --profile "$PROFILE" \
    --output "$METRICS_CSV" --seconds "$BENCHMARK_SECONDS"
fi

if [[ "$UDP_RELAY" == 1 ]]; then
  curl --noproxy '*' -fsS -b "$COOKIE" "$BASE/api/v2/torrents/info?hash=$INFO_HASH" > "$WORK_DIR/torrent-before-outage.json"
  PRE_OUTAGE_BYTES="$(python3 - "$WORK_DIR/torrent-before-outage.json" <<'PY'
import json, sys
print(int(json.load(open(sys.argv[1], encoding='utf-8'))[0].get('downloaded', 0)))
PY
)"
  touch "$RELAY_DROP"
  outage_detected=0
  for attempt in {1..90}; do
    curl --noproxy '*' -fsS -b "$COOKIE" "$BASE/api/v2/app/minttorrentVpnStatus" > "$WORK_DIR/vpn.json" || true
    if python3 - "$WORK_DIR/vpn.json" <<'PY'
import json, sys
try: status = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception: raise SystemExit(1)
raise SystemExit(0 if status.get('active') and not status.get('data_path_healthy') else 1)
PY
    then outage_detected=1; break; fi
    sleep 1
  done
  ((outage_detected == 1)) || { echo "VPN health did not detect the dropped UDP underlay" >&2; exit 1; }

  curl --noproxy '*' -fsS -b "$COOKIE" "$BASE/api/v2/torrents/info?hash=$INFO_HASH" > "$WORK_DIR/torrent-outage-start.json"
  OUTAGE_BYTES="$(python3 - "$WORK_DIR/torrent-outage-start.json" <<'PY'
import json, sys
print(int(json.load(open(sys.argv[1], encoding='utf-8'))[0].get('downloaded', 0)))
PY
)"
  sleep 8
  curl --noproxy '*' -fsS -b "$COOKIE" "$BASE/api/v2/torrents/info?hash=$INFO_HASH" > "$WORK_DIR/torrent-outage-end.json"
  python3 - "$WORK_DIR/torrent-outage-end.json" "$OUTAGE_BYTES" <<'PY'
import json, sys
status = json.load(open(sys.argv[1], encoding='utf-8'))[0]
assert int(status.get('downloaded', 0)) == int(sys.argv[2]), status
PY

  rm -f -- "$RELAY_DROP"
  recovered_without_reimport=0
  for attempt in {1..300}; do
    curl --noproxy '*' -fsS -b "$COOKIE" "$BASE/api/v2/app/minttorrentVpnStatus" > "$WORK_DIR/vpn.json" || true
    if python3 - "$WORK_DIR/vpn.json" <<'PY'
import json, sys
try: status = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception: raise SystemExit(1)
raise SystemExit(0 if status.get('enabled') and status.get('active') and status.get('data_path_healthy')
                 and status.get('last_handshake_ns') else 1)
PY
    then recovered_without_reimport=1; break; fi
    sleep 1
  done
  ((recovered_without_reimport == 1)) || { echo "AWG did not recover after restoring UDP forwarding" >&2; exit 1; }

  resumed=0
  for attempt in {1..180}; do
    curl --noproxy '*' -fsS -b "$COOKIE" "$BASE/api/v2/torrents/info?hash=$INFO_HASH" > "$WORK_DIR/torrent-resumed.json" || true
    if python3 - "$WORK_DIR/torrent-resumed.json" "$OUTAGE_BYTES" <<'PY'
import json, sys
try: torrent = json.load(open(sys.argv[1], encoding='utf-8'))[0]
except Exception: raise SystemExit(1)
raise SystemExit(0 if int(torrent.get('downloaded', 0)) > int(sys.argv[2]) else 1)
PY
    then resumed=1; break; fi
    sleep 1
  done
  ((resumed == 1)) || { echo "Torrent did not continue after AWG recovery" >&2; exit 1; }
  RECOVERED_BYTES="$(python3 - "$WORK_DIR/torrent-resumed.json" <<'PY'
import json, sys
print(int(json.load(open(sys.argv[1], encoding='utf-8'))[0].get('downloaded', 0)))
PY
)"
  echo "PASS: AWG recovered without profile re-import and the torrent resumed; bytes before outage=$OUTAGE_BYTES, after recovery=$RECOVERED_BYTES (initial=$PRE_OUTAGE_BYTES)."
fi

python3 - "$WORK_DIR/trackers.json" "$WORK_DIR/torrent.json" "$WORK_DIR/properties.json" "$TEST_SOURCE" "$INFO_HASH" "$WORK_DIR/maindata.json" "$WORK_DIR/peers.json" "$REQUIRE_DHT" "$REQUIRE_UTP" "$REQUIRE_PEX" "$REQUIRE_TCP" "$REQUIRE_IPV4" "$REQUIRE_IPV6" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1], encoding='utf-8'))
torrent = json.load(open(sys.argv[2], encoding='utf-8'))[0]
properties = json.load(open(sys.argv[3], encoding='utf-8'))
working = [r for r in rows if r.get('status') == 2]
assert torrent.get('downloaded', 0) > 0 and torrent.get('progress', 0) > 0 and properties.get('pieces_have', 0) > 0, (torrent, properties)
udp_working = [r for r in working if r.get('url', '').lower().startswith('udp://')]
if sys.argv[8] == '1':
    maindata = json.load(open(sys.argv[6], encoding='utf-8'))
    peer_data = json.load(open(sys.argv[7], encoding='utf-8'))
    nodes = maindata.get('server_state', {}).get('dht_nodes', 0)
    peers = peer_data.get('peers', {})
    transports = sorted({peer.get('connection', '?') for peer in peers.values()})
    assert nodes > 0 and peers, (nodes, peers)
    print(f"PASS: trackerless and webseed-free torrent discovered DHT nodes={nodes}, peers={len(peers)}, peer transports={transports}; downloaded {torrent['downloaded']} byte(s) through VPN; verified pieces={properties['pieces_have']}.")
else:
    assert working, rows
    peer_data = json.load(open(sys.argv[7], encoding='utf-8'))
    transports = sorted({str(peer.get('connection', '?')) for peer in peer_data.get('peers', {}).values()})
    pex = next((r for r in rows if r.get('url') == '** [PeX] **'), {})
    pex_count = int(pex.get('num_seeds', 0)) + int(pex.get('num_leeches', 0))
    normalized_transports = [t.lower().replace('μ', 'u').replace('µ', 'u') for t in transports]
    if sys.argv[9] == '1': assert any('utp' in t for t in normalized_transports), transports
    if sys.argv[10] == '1': assert pex_count > 0, pex
    if sys.argv[11] == '1': assert 'bt' in normalized_transports, transports
    import ipaddress
    payload_families = set()
    for peer in peer_data.get('peers', {}).values():
        try:
            transport = str(peer.get('connection', '')).lower().replace('μ', 'u').replace('µ', 'u')
            if int(peer.get('downloaded', 0)) > 0 and (transport == 'bt' or 'utp' in transport):
                payload_families.add(ipaddress.ip_address(peer.get('ip', '')).version)
        except (ValueError, TypeError):
            continue
    if sys.argv[12] == '1': assert 4 in payload_families, payload_families
    if sys.argv[13] == '1': assert 6 in payload_families, payload_families
    print(f"PASS: VPN disconnected/reconnected in WebUI; {sys.argv[4]} {sys.argv[5]} announced and downloaded {torrent['downloaded']} byte(s) through the reactivated libtorrent userspace socket path; verified pieces={properties['pieces_have']}; peer transports={transports}; payload address families={sorted(payload_families)}; PeX peers={pex_count}; successful rows={len(working)}; successful UDP tracker rows={len(udp_working)}.")
PY

if [[ "$AUDIT_NETWORK" == 1 ]]; then
  python3 - "$WORK_DIR/network.trace" "$WORK_DIR/source/awg.conf" <<'PY'
import ipaddress
import re
import sys

trace_path, profile_path = sys.argv[1:]
allowed = set()
in_peer = False
for line in open(profile_path, encoding='utf-8', errors='replace'):
    value = line.strip()
    if value.startswith('['):
        in_peer = value.lower() == '[peer]'
    elif in_peer and value.lower().startswith('endpoint'):
        host = value.split('=', 1)[1].strip().rsplit(':', 1)[0].strip('[]').split('%', 1)[0]
        try:
            allowed.add(str(ipaddress.ip_address(host)))
        except ValueError:
            pass
if not allowed:
    raise SystemExit('Profile has no numeric AWG peer endpoint; cannot audit host destinations')

observed = set()
for line in open(trace_path, encoding='utf-8', errors='replace'):
    if not re.search(r'\b(connect|sendto|sendmsg|sendmmsg)\(', line):
        continue
    hosts = re.findall(r'sin_addr=inet_addr\("([^"]+)"\)', line)
    hosts += re.findall(r'sin6_addr=inet_pton\(AF_INET6, "([^"]+)"\)', line)
    for host in hosts:
        try:
            address = ipaddress.ip_address(host)
        except ValueError:
            continue
        if not address.is_loopback and not address.is_unspecified and not address.is_multicast:
            observed.add(str(address))

unexpected = observed - allowed
awg = observed & allowed
print(f'Live torrent syscall audit: external destinations={len(observed)}, AWG endpoint destinations={len(awg)}, unexpected destinations={len(unexpected)}')
if not awg:
    raise SystemExit('No host-network syscall to the configured AWG endpoint was observed during this audited run')
if unexpected:
    raise SystemExit('Unexpected non-loopback system-network destinations were observed during torrent traffic')
PY
fi
