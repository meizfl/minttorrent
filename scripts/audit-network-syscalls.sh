#!/usr/bin/env bash
set -Eeuo pipefail

usage() { echo "Usage: $0 AWG_PROFILE [STANDALONE_BUNDLE_DIR]" >&2; exit 2; }
(($# >= 1 && $# <= 2)) || usage
PROFILE_FILE="$(realpath -- "$1")"
[[ -f "$PROFILE_FILE" ]] || { echo "AWG profile not found" >&2; exit 1; }
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if (($# == 2)); then
  BUNDLE_DIR="$(cd -- "$2" && pwd)"
elif [[ -x "$ROOT_DIR/bin/minttorrent" ]]; then
  BUNDLE_DIR="$ROOT_DIR"
else
  BUNDLE_DIR="$ROOT_DIR/dist/MintTorrent-$(cat "$ROOT_DIR/VERSION")-$(uname -m)-unknown-linux-gnu"
fi
LAUNCHER="$BUNDLE_DIR/bin/minttorrent"
[[ -x "$LAUNCHER" ]] || { echo "Bundle launcher not found" >&2; exit 1; }
PORT_HELPER="$BUNDLE_DIR/scripts/choose-loopback-test-port.py"
[[ -f "$PORT_HELPER" ]] || PORT_HELPER="$ROOT_DIR/scripts/choose-loopback-test-port.py"
command -v strace >/dev/null || { echo "strace is required" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
if [[ -n "${MINTTORRENT_TEST_WEBUI_PORT:-}" ]]; then
  WEBUI_PORT="$(python3 "$PORT_HELPER" "$MINTTORRENT_TEST_WEBUI_PORT")"
else
  WEBUI_PORT="$(python3 "$PORT_HELPER")"
fi
WEBUI_V4="http://127.0.0.1:$WEBUI_PORT"
RSS_URL="${MINTTORRENT_TEST_RSS_URL:-}"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/minttorrent-network-audit.XXXXXX")"
chmod 0700 "$WORK_DIR"
PROFILE_DIR="$WORK_DIR/profile"
LOG="$WORK_DIR/service.log"
TRACE="$WORK_DIR/network.trace"
COOKIE="$WORK_DIR/cookie.txt"
MINTTORRENT_PROFILE="$PROFILE_DIR" strace -f -qq -e trace=network -o "$TRACE" "$LAUNCHER" --webui-port="$WEBUI_PORT" >"$LOG" 2>&1 &
PID=$!
stop_profile_instance() {
  python3 - "$PROFILE_DIR" TERM <<'PY'
import os, signal, sys
profile = os.path.realpath(sys.argv[1])
for name in os.listdir('/proc'):
    if not name.isdigit(): continue
    try: args = open(f'/proc/{name}/cmdline', 'rb').read().split(b'\0')
    except OSError: continue
    if not args or not args[0].endswith(b'/qbittorrent-nox'): continue
    profiles = [arg.split(b'=', 1)[1].decode(errors='replace') for arg in args if arg.startswith(b'--profile=')]
    if any(os.path.realpath(value) == profile for value in profiles):
        try: os.kill(int(name), signal.SIGTERM)
        except ProcessLookupError: pass
PY
  for _ in {1..50}; do
    if ! python3 - "$PROFILE_DIR" <<'PY'
import os, sys
profile = os.path.realpath(sys.argv[1])
for name in os.listdir('/proc'):
    if not name.isdigit(): continue
    try: args = open(f'/proc/{name}/cmdline', 'rb').read().split(b'\0')
    except OSError: continue
    if args and args[0].endswith(b'/qbittorrent-nox'):
        paths = [arg.split(b'=', 1)[1].decode(errors='replace') for arg in args if arg.startswith(b'--profile=')]
        if any(os.path.realpath(path) == profile for path in paths): sys.exit(0)
sys.exit(1)
PY
    then break; fi
    sleep 0.1
  done
  python3 - "$PROFILE_DIR" KILL <<'PY'
import os, signal, sys
profile = os.path.realpath(sys.argv[1])
for name in os.listdir('/proc'):
    if not name.isdigit(): continue
    try: args = open(f'/proc/{name}/cmdline', 'rb').read().split(b'\0')
    except OSError: continue
    if not args or not args[0].endswith(b'/qbittorrent-nox'): continue
    profiles = [arg.split(b'=', 1)[1].decode(errors='replace') for arg in args if arg.startswith(b'--profile=')]
    if any(os.path.realpath(value) == profile for value in profiles):
        try: os.kill(int(name), signal.SIGKILL)
        except ProcessLookupError: pass
PY
}
cleanup() {
  # Terminate qBittorrent by its unique temporary profile. Killing strace
  # alone detaches the tracee and leaves the service running.
  stop_profile_instance
  kill -TERM "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
  rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT INT TERM

for _ in {1..30}; do
  code="$(curl --noproxy '*' --connect-timeout 2 -sS -o /dev/null -w '%{http_code}' "$WEBUI_V4/" 2>/dev/null || true)"
  [[ "$code" == 200 ]] && break
  kill -0 "$PID" 2>/dev/null || { echo "MintTorrent exited before WebUI startup" >&2; exit 1; }
  sleep 1
done
[[ "$code" == 200 ]] || { echo "WebUI did not bind at $WEBUI_V4" >&2; exit 1; }
password="$(sed -nE '/temporary password|тимчасовий пароль/Is/.*: ([[:alnum:]]+).*/\1/p' "$LOG" | tail -n1)"
[[ -n "$password" ]] || { echo "First-run WebUI credential was not emitted" >&2; exit 1; }
MINTTORRENT_WEBUI_URL="$WEBUI_V4" MINTTORRENT_WEBUI_PASSWORD="$password" "$LAUNCHER" vpn import "$PROFILE_FILE"

for _ in {1..30}; do
  MINTTORRENT_WEBUI_URL="$WEBUI_V4" MINTTORRENT_WEBUI_PASSWORD="$password" "$LAUNCHER" vpn status > "$WORK_DIR/status.json"
  if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("data_path_healthy") else 1)' "$WORK_DIR/status.json"; then break; fi
  sleep 2
done

if [[ -n "$RSS_URL" ]]; then
  login_code="$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' -c "$COOKIE" \
    --data-urlencode username=admin --data-urlencode "password=$password" "$WEBUI_V4/api/v2/auth/login")"
  [[ "$login_code" == 200 || "$login_code" == 204 ]] || { echo "WebUI login failed during RSS syscall audit" >&2; exit 1; }
  RSS_PATH="MintTorrent-RSS-network-audit"
  curl --noproxy '*' -fsS -b "$COOKIE" -X POST \
    --data-urlencode "url=$RSS_URL" --data-urlencode "path=$RSS_PATH" --data-urlencode refreshInterval=0 \
    "$WEBUI_V4/api/v2/rss/addFeed" > /dev/null
  curl --noproxy '*' -fsS -b "$COOKIE" -X POST --data-urlencode "itemPath=$RSS_PATH" \
    "$WEBUI_V4/api/v2/rss/refreshItem" > /dev/null
  rss_ready=0
  for attempt in {1..120}; do
    curl --noproxy '*' -fsS -b "$COOKIE" --get --data-urlencode withData=true \
      "$WEBUI_V4/api/v2/rss/items" > "$WORK_DIR/rss-items.json"
    if python3 - "$WORK_DIR/rss-items.json" "$RSS_URL" <<'PY'
import json, sys
def find_feed(node, url):
    if isinstance(node, dict):
        if node.get('url') == url and node.get('articles') is not None:
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
    if ((attempt % 20 == 0)); then echo "Waiting for RSS feed through gVisor during syscall audit (${attempt} s)..."; fi
    sleep 1
  done
  ((rss_ready == 1)) || { echo "RSS feed did not return parsed articles through gVisor" >&2; exit 1; }
  curl --noproxy '*' -fsS -b "$COOKIE" -X POST --data-urlencode "path=$RSS_PATH" \
    "$WEBUI_V4/api/v2/rss/removeItem" > /dev/null
fi

python3 - "$TRACE" "$PROFILE_FILE" "$WORK_DIR/status.json" <<'PY'
import ipaddress
import json
import re
import sys

trace_path, profile_path, status_path = sys.argv[1:]
allowed = set()
in_peer = False
for line in open(profile_path, encoding="utf-8", errors="replace"):
    value = line.strip()
    if value.startswith("["):
        in_peer = value.lower() == "[peer]"
    elif in_peer and value.lower().startswith("endpoint"):
        host = value.split("=", 1)[1].strip().rsplit(":", 1)[0].strip("[]").split("%", 1)[0]
        try:
            allowed.add(str(ipaddress.ip_address(host)))
        except ValueError:
            pass
if not allowed:
    raise SystemExit("Profile has no numeric AWG peer endpoint")

observed = set()
for line in open(trace_path, encoding="utf-8", errors="replace"):
    if not re.search(r"\b(connect|sendto|sendmsg|sendmmsg)\(", line):
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

status = json.load(open(status_path, encoding="utf-8"))
if not status.get("active") or not status.get("data_path_healthy") or not status.get("last_handshake_ns"):
    raise SystemExit("VPN handshake or in-stack DNS+TCP health probe did not pass")
unexpected = observed - allowed
print(f"VPN health: PASS; non-loopback syscall destinations: {len(observed)}; AWG endpoint: {len(observed & allowed)}; unexpected: {len(unexpected)}")
if unexpected:
    raise SystemExit("Unexpected external destinations: " + ", ".join(sorted(unexpected)))
PY

MINTTORRENT_WEBUI_URL="$WEBUI_V4" MINTTORRENT_WEBUI_PASSWORD="$password" "$LAUNCHER" vpn disconnect
MINTTORRENT_WEBUI_URL="$WEBUI_V4" MINTTORRENT_WEBUI_PASSWORD="$password" "$LAUNCHER" vpn status > "$WORK_DIR/stopped.json"
python3 - "$WORK_DIR/stopped.json" <<'PY'
import json
import sys

status = json.load(open(sys.argv[1], encoding="utf-8"))
if status.get("enabled") or status.get("active"):
    raise SystemExit("VPN CLI disconnect did not stop the userspace stack")
PY

if [[ -n "$RSS_URL" ]]; then
  echo "RSS fetch/parse: PASS through gVisor under strace. No torrents were added; torrent-traffic packet capture remains separate."
else
  echo "No torrents were added. This syscall audit verifies only the AWG health-probe process path; it does not replace torrent-traffic packet capture."
fi
