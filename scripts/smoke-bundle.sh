#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if (($#)); then
  BUNDLE_DIR="$1"
elif [[ -x "$ROOT_DIR/bin/minttorrent" ]]; then
  BUNDLE_DIR="$ROOT_DIR"
else
  BUNDLE_DIR="$ROOT_DIR/dist/MintTorrent-$(cat "$ROOT_DIR/VERSION")-$(uname -m)-unknown-linux-gnu"
fi
BUNDLE_DIR="$(cd -- "$BUNDLE_DIR" && pwd)"
LAUNCHER="$BUNDLE_DIR/bin/minttorrent"
[[ -x "$LAUNCHER" ]] || { echo "Bundle launcher not found: $LAUNCHER" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
if [[ -n "${MINTTORRENT_TEST_WEBUI_PORT:-}" ]]; then
  WEBUI_PORT="$(python3 "$ROOT_DIR/scripts/choose-loopback-test-port.py" "$MINTTORRENT_TEST_WEBUI_PORT")"
else
  WEBUI_PORT="$(python3 "$ROOT_DIR/scripts/choose-loopback-test-port.py")"
fi
WEBUI_V4="http://127.0.0.1:$WEBUI_PORT"
WEBUI_V6="http://[::1]:$WEBUI_PORT"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/minttorrent-smoke.XXXXXX")"
PROFILE="$WORK_DIR/profile"
LOG="$WORK_DIR/service.log"
COOKIE="$WORK_DIR/cookie.txt"
mkdir -p "$WORK_DIR/vpn"
cp "$BUNDLE_DIR/config/vpn/default.conf" "$WORK_DIR/vpn/default.conf"
cat > "$WORK_DIR/config.toml" <<CONFIG
[vpn]
config = "$WORK_DIR/vpn/default.conf"
autostart = false
[torrent]
webui_port = $WEBUI_PORT
listen_port = 0
[torrent.storage]
download_path = ""
CONFIG
export MINTTORRENT_CONFIG="$WORK_DIR/config.toml" MINTTORRENT_PROFILE="$PROFILE"
"$LAUNCHER" >"$LOG" 2>&1 &
PID=$!

stop_profile_instance() {
  python3 - "$PROFILE" TERM <<'PY'
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
    if ! python3 - "$PROFILE" <<'PY'
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
  python3 - "$PROFILE" KILL <<'PY'
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
  stop_profile_instance
  kill -TERM "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
  if [[ "${MINTTORRENT_SMOKE_KEEP_WORK:-0}" == 1 ]]; then
    echo "Preserved smoke work directory: $WORK_DIR" >&2
  else
    rm -rf -- "$WORK_DIR"
  fi
}
trap cleanup EXIT INT TERM

for _ in {1..30}; do
  v4="$(curl --noproxy '*' --connect-timeout 2 -sS -o "$WORK_DIR/v4.html" -w '%{http_code}' "$WEBUI_V4/" 2>/dev/null || true)"
  v6="$(curl --noproxy '*' --connect-timeout 2 -g -sS -o "$WORK_DIR/v6.html" -w '%{http_code}' "$WEBUI_V6/" 2>/dev/null || true)"
  if [[ "$v4" == 200 && "$v6" == 200 ]]; then
    kill -0 "$PID" 2>/dev/null || { echo "MintTorrent exited during startup; private log was at $LOG" >&2; exit 1; }
    break
  fi
  kill -0 "$PID" 2>/dev/null || { echo "MintTorrent exited during startup; private log was at $LOG" >&2; exit 1; }
  sleep 1
done
[[ "$v4" == 200 && "$v6" == 200 ]] || { echo "WebUI loopback check failed (IPv4=$v4 IPv6=$v6)" >&2; exit 1; }
grep -qi 'MintTorrent' "$WORK_DIR/v4.html" || { echo "MintTorrent branding was not found in the WebUI" >&2; exit 1; }

password="$(sed -nE '/temporary password|тимчасовий пароль/Is/.*: ([[:alnum:]]+).*/\1/p' "$LOG" | tail -n1)"
if [[ -z "$password" ]]; then
  echo "qBittorrent did not emit a first-run WebUI password; sanitized startup log follows:" >&2
  python3 - "$LOG" <<'PY' >&2
import re
import sys

for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    if re.search(r"password|пароль", line, re.IGNORECASE):
        print("[credential-related log line redacted]")
    else:
        print(line.rstrip()[:400])
PY
  exit 1
fi
login_code="$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' -c "$COOKIE" \
  --data-urlencode username=admin --data-urlencode "password=$password" \
  "$WEBUI_V4/api/v2/auth/login")"
[[ "$login_code" == 200 || "$login_code" == 204 ]] || { echo "WebUI login failed (HTTP $login_code)" >&2; exit 1; }

version="$(curl --noproxy '*' -fsS -b "$COOKIE" "$WEBUI_V4/api/v2/app/version")"
[[ "$version" == "0.1.0" ]] || { echo "Unexpected MintTorrent API version: $version" >&2; exit 1; }
curl --noproxy '*' -fsS -b "$COOKIE" \
  "$WEBUI_V4/api/v2/log/main?normal=true&info=true&warning=true&critical=true" > "$WORK_DIR/identity-log.json"
python3 - "$WORK_DIR/identity-log.json" "$version" <<'PY'
import json
import sys
rows = json.load(open(sys.argv[1], encoding="utf-8"))
messages = [row.get("message", "") for row in rows]
expected = f"MintTorrent/{sys.argv[2]} qBittorrent/5.3.0 libtorrent/2.1.2.0"
http = next((message for message in messages if "HTTP" in message and expected in message), "")
peer = next((message for message in messages if "BitTorrent extension-handshake client version:" in message), "")
peer_id = next((message for message in messages if "BitTorrent peer ID fingerprint:" in message), "")
assert expected in http, (http, messages)
assert expected in peer, (peer, messages)
assert '"-qB5300-"' in peer_id, (peer_id, messages)
http_value = http.rsplit('"', 2)[-2]
peer_value = peer.rsplit('"', 2)[-2]
assert http_value == peer_value, (http_value, peer_value)
PY
curl --noproxy '*' -fsS -b "$COOKIE" "$WEBUI_V4/api/v2/app/networkInterfaceList" > "$WORK_DIR/interfaces.json"
curl --noproxy '*' -fsS -b "$COOKIE" "$WEBUI_V4/api/v2/app/networkInterfaceAddressList?iface=" > "$WORK_DIR/interface-addresses.json"
python3 - "$WORK_DIR/interfaces.json" "$WORK_DIR/interface-addresses.json" <<'PY'
import json
import sys

interfaces, addresses = [json.load(open(path, encoding="utf-8")) for path in sys.argv[1:]]
assert interfaces == [], interfaces
assert addresses == [], addresses
PY
curl --noproxy '*' -fsS -b "$COOKIE" -X POST \
  --data-urlencode 'json={"current_network_interface":"eth0","current_interface_address":"192.0.2.10","proxy_type":"SOCKS5","proxy_ip":"127.0.0.1","proxy_port":1080,"proxy_auth_enabled":true,"proxy_username":"must-not-persist","proxy_password":"must-not-persist","proxy_bittorrent":true,"proxy_peer_connections":true,"proxy_rss":true,"proxy_misc":true}' \
  "$WEBUI_V4/api/v2/app/setPreferences" > /dev/null
curl --noproxy '*' -fsS -b "$COOKIE" -X POST \
  --data-urlencode 'json={"proxy_type":"HTTP","proxy_ip":"127.0.0.1","proxy_port":8080,"proxy_auth_enabled":true,"proxy_username":"must-not-persist","proxy_password":"must-not-persist","proxy_bittorrent":true,"proxy_peer_connections":true,"proxy_rss":true,"proxy_misc":true}' \
  "$WEBUI_V4/api/v2/app/setPreferences" > /dev/null
curl --noproxy '*' -fsS -b "$COOKIE" "$WEBUI_V4/api/v2/app/preferences" > "$WORK_DIR/preferences.json"
python3 - "$WORK_DIR/preferences.json" "$WEBUI_PORT" "$LOG" <<'PY'
import json
import re
import sys

preferences = json.load(open(sys.argv[1], encoding="utf-8"))
assert preferences["current_network_interface"] == "", preferences.get("current_network_interface")
assert preferences["current_interface_address"] == "", preferences.get("current_interface_address")
assert preferences["proxy_type"] == "None", preferences.get("proxy_type")
assert preferences["proxy_ip"] == "" and preferences["proxy_port"] == 0, preferences
assert not preferences["proxy_auth_enabled"] and not preferences["proxy_username"] and not preferences["proxy_password"], preferences
assert not preferences["proxy_bittorrent"] and not preferences["proxy_peer_connections"]
assert not preferences["proxy_rss"] and not preferences["proxy_misc"]
assert preferences["save_path"].endswith("/profile/downloads"), preferences.get("save_path")
assert preferences["web_ui_port"] == int(sys.argv[2]), preferences.get("web_ui_port")
match = re.search(r"Selected BitTorrent listen port for this service run port=(\d+)", open(sys.argv[3], encoding="utf-8").read())
assert match, "startup did not report the selected torrent port"
selected = int(match.group(1))
assert 10000 <= selected <= 65535, selected
assert preferences["listen_port"] == selected, (preferences.get("listen_port"), selected)
PY
curl --noproxy '*' -fsS -b "$COOKIE" "$WEBUI_V4/api/v2/app/minttorrentVpnStatus" > "$WORK_DIR/vpn.json"
curl --noproxy '*' -fsS -b "$COOKIE" "$WEBUI_V4/api/v2/transfer/info" > "$WORK_DIR/transfer.json"
curl --noproxy '*' -fsS -b "$COOKIE" "$WEBUI_V4/api/v2/app/minttorrentVpnProfile" > "$WORK_DIR/active-vpn.conf"
python3 - "$WORK_DIR/vpn.json" "$WORK_DIR/transfer.json" "$WORK_DIR/active-vpn.conf" "$BUNDLE_DIR/config/vpn/default.conf" <<'PY'
import json
import os
import stat
import sys

status = json.load(open(sys.argv[1], encoding="utf-8"))
transfer = json.load(open(sys.argv[2], encoding="utf-8"))
assert status["active"] is False, status
assert status["configured"] is True, status
assert status["enabled"] is False, status
for key in ("minttorrent_dht_bytes_in", "minttorrent_dht_bytes_out", "minttorrent_dht_rate_in", "minttorrent_dht_rate_out", "minttorrent_dht_messages_in", "minttorrent_dht_messages_out", "minttorrent_dht_messages_in_dropped"):
    assert isinstance(transfer.get(key), int) and transfer[key] >= 0, (key, transfer)
assert open(sys.argv[3], "rb").read() == open(sys.argv[4], "rb").read()
assert stat.S_IMODE(os.stat(status["profile_path"]).st_mode) == 0o600, status["profile_path"]
PY
# Exercise settings-page VPN actions and input validation without starting the
# transport. Invalid Netstack values must be rejected before profile mutation.
for invalid_settings in '575:1024:1048576:1048576' '0:16385:1048576:1048576' \
                        '0:1024:8192:1048576' '0:1024:1048576:16777217'; do
  IFS=: read -r mtu queue tcp_send tcp_receive <<< "$invalid_settings"
  code="$(curl --noproxy '*' -sS -o "$WORK_DIR/netstack-invalid-response.txt" -w '%{http_code}' \
    -b "$COOKIE" -X POST --data-urlencode 'profile=invalid-profile' \
    --data-urlencode ipv4=true --data-urlencode ipv6=true --data-urlencode "mtu=$mtu" \
    --data-urlencode "packet_queue=$queue" --data-urlencode "tcp_send_buffer=$tcp_send" \
    --data-urlencode "tcp_receive_buffer=$tcp_receive" "$WEBUI_V4/api/v2/app/minttorrentVpnImport")"
  [[ "$code" == 415 ]] || { echo "Invalid Netstack settings returned HTTP $code instead of 415" >&2; exit 1; }
done
curl --noproxy '*' -fsS -b "$COOKIE" -X POST --data-urlencode enabled=false \
  "$WEBUI_V4/api/v2/app/minttorrentVpnSet" > /dev/null
code="$(curl --noproxy '*' -sS -o "$WORK_DIR/vpn-toggle-invalid-response.txt" -w '%{http_code}' \
  -b "$COOKIE" -X POST --data-urlencode enabled=maybe "$WEBUI_V4/api/v2/app/minttorrentVpnSet")"
[[ "$code" == 400 ]] || { echo "Invalid VPN toggle value returned HTTP $code instead of 400" >&2; exit 1; }
curl --noproxy '*' -fsS -b "$COOKIE" "$WEBUI_V4/api/v2/app/minttorrentVpnStatus" > "$WORK_DIR/vpn-after-validation.json"
curl --noproxy '*' -fsS -b "$COOKIE" "$WEBUI_V4/api/v2/app/minttorrentVpnProfile" > "$WORK_DIR/vpn-profile-after-validation.conf"
python3 - "$WORK_DIR/vpn-after-validation.json" "$WORK_DIR/vpn-profile-after-validation.conf" "$BUNDLE_DIR/config/vpn/default.conf" <<'PY'
import json, sys
status = json.load(open(sys.argv[1], encoding="utf-8"))
assert not status["enabled"] and not status["active"], status
assert open(sys.argv[2], "rb").read() == open(sys.argv[3], "rb").read(), "rejected input changed the saved profile"
PY
curl --noproxy '*' -fsS -b "$COOKIE" "$WEBUI_V4/views/preferences.html" > "$WORK_DIR/preferences.html"
grep -Eq 'NetstackTab|mintTorrentNetstack' "$WORK_DIR/preferences.html" || {
  echo "MintTorrent Netstack settings tab was not served" >&2
  exit 1
}
grep -q 'mintTorrentIncomingPeerLimit' "$WORK_DIR/preferences.html" || {
  echo "Incoming peer reachability limitation was not shown" >&2
  exit 1
}
grep -q 'minttorrentVpnProfile' "$WORK_DIR/preferences.html" || {
  echo "Saved VPN profile editor was not served" >&2
  exit 1
}
grep -q 'SOCKS and HTTP CONNECT proxies are disabled' "$WORK_DIR/preferences.html" || {
  echo "MintTorrent proxy restriction notice was not served" >&2
  exit 1
}
grep -q 'id="upstreamProxySettings" style="display:none"' "$WORK_DIR/preferences.html" || {
  echo "Upstream proxy controls were not hidden in MintTorrent" >&2
  exit 1
}

# Exercise qBittorrent's RSS auto-downloader rule API without adding a feed or
# allowing any network request: create, inspect, clone, rename, export and remove.
python3 - "$WORK_DIR/rss-rule.json" <<'PY'
import json, sys
json.dump({
    "enabled": True,
    "priority": 0,
    "useRegex": False,
    "mustContain": "minttorrent-smoke",
    "mustNotContain": "",
    "episodeFilter": "",
    "affectedFeeds": [],
    "lastMatch": "",
    "ignoreDays": 0,
    "smartFilter": False,
    "previouslyMatchedEpisodes": [],
    "torrentParams": {},
}, open(sys.argv[1], "w", encoding="utf-8"))
PY
curl --noproxy '*' -fsS -b "$COOKIE" -X POST --data-urlencode ruleName=MintTorrentSmokeRule \
  --data-urlencode "ruleDef@$WORK_DIR/rss-rule.json" "$WEBUI_V4/api/v2/rss/setRule" > /dev/null
curl --noproxy '*' -fsS -b "$COOKIE" "$WEBUI_V4/api/v2/rss/rules" > "$WORK_DIR/rss-rules.json"
python3 - "$WORK_DIR/rss-rules.json" <<'PY'
import json, sys
rules = json.load(open(sys.argv[1], encoding="utf-8"))
assert rules["MintTorrentSmokeRule"]["mustContain"] == "minttorrent-smoke", rules
PY
curl --noproxy '*' -fsS -b "$COOKIE" -X POST --data-urlencode sourceName=MintTorrentSmokeRule \
  --data-urlencode cloneName=MintTorrentSmokeClone "$WEBUI_V4/api/v2/rss/cloneRule" > /dev/null
curl --noproxy '*' -fsS -b "$COOKIE" -X POST --data-urlencode ruleName=MintTorrentSmokeClone \
  --data-urlencode newRuleName=MintTorrentSmokeRenamed "$WEBUI_V4/api/v2/rss/renameRule" > /dev/null
curl --noproxy '*' -fsS -b "$COOKIE" "$WEBUI_V4/api/v2/rss/exportRules" > "$WORK_DIR/rss-rules-export.json"
python3 - "$WORK_DIR/rss-rules-export.json" <<'PY'
import json, sys
rules = json.load(open(sys.argv[1], encoding="utf-8"))
assert "MintTorrentSmokeRule" in rules and "MintTorrentSmokeRenamed" in rules, rules
PY
curl --noproxy '*' -fsS -b "$COOKIE" -X POST --data-urlencode ruleName=MintTorrentSmokeRule \
  "$WEBUI_V4/api/v2/rss/removeRule" > /dev/null
curl --noproxy '*' -fsS -b "$COOKIE" -X POST --data-urlencode ruleName=MintTorrentSmokeRenamed \
  "$WEBUI_V4/api/v2/rss/removeRule" > /dev/null
curl --noproxy '*' -fsS -b "$COOKIE" "$WEBUI_V4/api/v2/rss/rules" > "$WORK_DIR/rss-rules-empty.json"
python3 - "$WORK_DIR/rss-rules-empty.json" <<'PY'
import json, sys
assert json.load(open(sys.argv[1], encoding="utf-8")) == {}
PY

# Exercise the qBittorrent torrent lifecycle without contacting trackers or
# peers: add a valid synthetic torrent in a stopped state, inspect it, then
# delete only the torrent record and leave the temporary data directory intact.
python3 - "$WORK_DIR/lifecycle.torrent" <<'PY'
import hashlib
import sys

def bencode(value):
    if isinstance(value, int):
        return b"i" + str(value).encode() + b"e"
    if isinstance(value, bytes):
        return str(len(value)).encode() + b":" + value
    if isinstance(value, list):
        return b"l" + b"".join(bencode(item) for item in value) + b"e"
    if isinstance(value, dict):
        return b"d" + b"".join(bencode(key) + bencode(value[key]) for key in sorted(value)) + b"e"
    raise TypeError(type(value))

payload = b"MintTorrent smoke lifecycle payload\n"
info = {
    b"length": len(payload),
    b"name": b"minttorrent-smoke-payload.bin",
    b"piece length": 16384,
    b"pieces": hashlib.sha1(payload).digest(),
}
with open(sys.argv[1], "wb") as torrent:
    torrent.write(bencode({b"info": info}))
PY
curl --noproxy '*' -fsS -b "$COOKIE" \
  -F "torrents=@$WORK_DIR/lifecycle.torrent;type=application/x-bittorrent" \
  -F stopped=true -F "savepath=$WORK_DIR/downloads" \
  "$WEBUI_V4/api/v2/torrents/add" > "$WORK_DIR/torrent-add.json"
python3 - "$WORK_DIR/torrent-add.json" <<'PY'
import json
import sys
result = json.load(open(sys.argv[1], encoding="utf-8"))
assert result["success_count"] == 1 and result["failure_count"] == 0, result
assert len(result["added_torrent_ids"]) == 1, result
PY
hash="$(python3 - "$WORK_DIR/torrent-add.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["added_torrent_ids"][0])
PY
)"

# Exercise the original tracker and peer-control APIs while the torrent is
# stopped. The reserved .invalid tracker is metadata only; no announce occurs.
tracker_url="http://minttorrent-smoke.invalid:8080/announce"
curl --noproxy '*' -fsS -b "$COOKIE" -X POST \
  --data-urlencode "hash=$hash" --data-urlencode "urls=$tracker_url" \
  "$WEBUI_V4/api/v2/torrents/addTrackers" > /dev/null
curl --noproxy '*' -fsS -b "$COOKIE" --get --data-urlencode "hash=$hash" \
  "$WEBUI_V4/api/v2/torrents/trackers" > "$WORK_DIR/trackers.json"
python3 - "$WORK_DIR/trackers.json" "$tracker_url" <<'PY'
import json
import sys
trackers = json.load(open(sys.argv[1], encoding="utf-8"))
assert any(row.get("url") == sys.argv[2] for row in trackers), trackers
PY
curl --noproxy '*' -fsS -b "$COOKIE" -X POST \
  --data-urlencode "hash=$hash" --data-urlencode "urls=$tracker_url" \
  "$WEBUI_V4/api/v2/torrents/removeTrackers" > /dev/null
curl --noproxy '*' -fsS -b "$COOKIE" --get --data-urlencode "hash=$hash" \
  "$WEBUI_V4/api/v2/torrents/trackers" > "$WORK_DIR/trackers-after-remove.json"
python3 - "$WORK_DIR/trackers-after-remove.json" "$tracker_url" <<'PY'
import json
import sys
trackers = json.load(open(sys.argv[1], encoding="utf-8"))
assert not any(row.get("url") == sys.argv[2] for row in trackers), trackers
PY

# A documentation-range address tests peer blocking without contacting a peer.
curl --noproxy '*' -fsS -b "$COOKIE" -X POST \
  --data-urlencode 'peers=203.0.113.7:6881' \
  "$WEBUI_V4/api/v2/transfer/banPeers" > /dev/null
curl --noproxy '*' -fsS -b "$COOKIE" "$WEBUI_V4/api/v2/app/preferences" > "$WORK_DIR/preferences-peer-ban.json"
python3 - "$WORK_DIR/preferences-peer-ban.json" <<'PY'
import json
import sys
preferences = json.load(open(sys.argv[1], encoding="utf-8"))
assert "203.0.113.7" in preferences["banned_IPs"].splitlines(), preferences.get("banned_IPs")
PY

# Verify mutable transfer-rate limits, then restore unlimited mode in the
# temporary service profile.
curl --noproxy '*' -fsS -b "$COOKIE" -X POST \
  --data-urlencode limit=4096 "$WEBUI_V4/api/v2/transfer/setUploadLimit" > /dev/null
curl --noproxy '*' -fsS -b "$COOKIE" -X POST \
  --data-urlencode limit=8192 "$WEBUI_V4/api/v2/transfer/setDownloadLimit" > /dev/null
curl --noproxy '*' -fsS -b "$COOKIE" "$WEBUI_V4/api/v2/transfer/uploadLimit" > "$WORK_DIR/upload-limit.txt"
curl --noproxy '*' -fsS -b "$COOKIE" "$WEBUI_V4/api/v2/transfer/downloadLimit" > "$WORK_DIR/download-limit.txt"
python3 - "$WORK_DIR/upload-limit.txt" "$WORK_DIR/download-limit.txt" <<'PY'
import sys
assert int(open(sys.argv[1], encoding="utf-8").read()) == 4096
assert int(open(sys.argv[2], encoding="utf-8").read()) == 8192
PY
curl --noproxy '*' -fsS -b "$COOKIE" -X POST \
  --data-urlencode limit=0 "$WEBUI_V4/api/v2/transfer/setUploadLimit" > /dev/null
curl --noproxy '*' -fsS -b "$COOKIE" -X POST \
  --data-urlencode limit=0 "$WEBUI_V4/api/v2/transfer/setDownloadLimit" > /dev/null

curl --noproxy '*' -fsS -b "$COOKIE" -X POST \
  --data-urlencode category=minttorrent-smoke --data-urlencode "savePath=$WORK_DIR/downloads" \
  "$WEBUI_V4/api/v2/torrents/createCategory" > /dev/null
curl --noproxy '*' -fsS -b "$COOKIE" -X POST \
  --data-urlencode "hashes=$hash" --data-urlencode category=minttorrent-smoke \
  "$WEBUI_V4/api/v2/torrents/setCategory" > /dev/null
curl --noproxy '*' -fsS -b "$COOKIE" -X POST \
  --data-urlencode "hashes=$hash" --data-urlencode tags=minttorrent-smoke \
  "$WEBUI_V4/api/v2/torrents/addTags" > /dev/null
curl --noproxy '*' -fsS -b "$COOKIE" --get --data-urlencode "hash=$hash" \
  "$WEBUI_V4/api/v2/torrents/files" > "$WORK_DIR/torrent-files.json"
python3 - "$WORK_DIR/torrent-files.json" <<'PY'
import json
import sys
files = json.load(open(sys.argv[1], encoding="utf-8"))
assert len(files) == 1 and files[0]["name"] == "minttorrent-smoke-payload.bin", files
PY
curl --noproxy '*' -fsS -b "$COOKIE" -X POST \
  --data-urlencode "hash=$hash" --data-urlencode id=0 --data-urlencode priority=1 \
  "$WEBUI_V4/api/v2/torrents/filePrio" > /dev/null
curl --noproxy '*' -fsS -b "$COOKIE" --get --data-urlencode "hash=$hash" \
  "$WEBUI_V4/api/v2/torrents/files" > "$WORK_DIR/torrent-files-priority.json"
python3 - "$WORK_DIR/torrent-files-priority.json" <<'PY'
import json
import sys
files = json.load(open(sys.argv[1], encoding="utf-8"))
assert len(files) == 1 and files[0]["priority"] == 1, files
PY
curl --noproxy '*' -fsS -b "$COOKIE" -X POST --data-urlencode "hashes=$hash" \
  "$WEBUI_V4/api/v2/torrents/start" > /dev/null
curl --noproxy '*' -fsS -b "$COOKIE" -X POST --data-urlencode "hashes=$hash" \
  "$WEBUI_V4/api/v2/torrents/stop" > /dev/null
curl --noproxy '*' -fsS -b "$COOKIE" --get \
  --data-urlencode "hashes=$hash" "$WEBUI_V4/api/v2/torrents/info" > "$WORK_DIR/torrent-info.json"
python3 - "$WORK_DIR/torrent-info.json" "$hash" <<'PY'
import json
import sys
torrents = json.load(open(sys.argv[1], encoding="utf-8"))
assert len(torrents) == 1 and torrents[0]["hash"] == sys.argv[2], torrents
assert torrents[0]["name"] == "minttorrent-smoke-payload.bin", torrents[0]
assert torrents[0]["category"] == "minttorrent-smoke", torrents[0]
assert torrents[0]["tags"] == "minttorrent-smoke", torrents[0]
PY
python3 "$BUNDLE_DIR/scripts/sample-qbittorrent-metrics.py" \
  --url "$WEBUI_V4" --cookie "$COOKIE" --hash "$hash" --profile "$PROFILE" \
  --output "$WORK_DIR/metrics.csv" --seconds 1 --interval 0.25
python3 - "$WORK_DIR/metrics.csv" <<'PY'
import csv
import sys
with open(sys.argv[1], newline="", encoding="utf-8") as stream:
    rows = list(csv.DictReader(stream))
assert len(rows) >= 2, rows
assert {"download_bytes_per_second", "connected_peers", "process_cpu_percent_of_one_core", "process_rss_kib", "peer_rtt_avg_ms", "session_download_bytes_per_second", "dht_nodes", "connection_status"} <= set(rows[0]), rows[0]
PY

# Verify that qBittorrent writes and reloads the stopped torrent record on a
# clean application restart. The synthetic torrent has no tracker or web seed,
# and is stopped before the service is shut down.
curl --noproxy '*' -fsS -b "$COOKIE" -X POST \
  "$WEBUI_V4/api/v2/app/shutdown" > /dev/null || true
stopped=0
for _ in {1..50}; do
  code="$(curl --noproxy '*' --connect-timeout 1 -sS -o /dev/null -w '%{http_code}' "$WEBUI_V4/" 2>/dev/null || true)"
  if [[ "$code" != 200 ]]; then stopped=1; break; fi
  sleep 0.1
done
((stopped == 1)) || { echo "qBittorrent did not stop after the authenticated shutdown API call" >&2; exit 1; }
wait "$PID" || true

"$LAUNCHER" >>"$LOG" 2>&1 &
PID=$!
for _ in {1..30}; do
  code="$(curl --noproxy '*' --connect-timeout 1 -sS -o /dev/null -w '%{http_code}' "$WEBUI_V4/" 2>/dev/null || true)"
  [[ "$code" == 200 ]] && break
  kill -0 "$PID" 2>/dev/null || { echo "MintTorrent exited during restart; inspect the private smoke log" >&2; exit 1; }
  sleep 1
done
[[ "${code:-}" == 200 ]] || { echo "WebUI did not return after the clean restart" >&2; exit 1; }
restarted_password="$(sed -nE '/temporary password|тимчасовий пароль/Is/.*: ([[:alnum:]]+).*/\1/p' "$LOG" | tail -n1)"
[[ -n "$restarted_password" ]] && password="$restarted_password"
login="$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' -c "$COOKIE" -b "$COOKIE" \
  --data-urlencode username=admin --data-urlencode "password=$password" "$WEBUI_V4/api/v2/auth/login")"
[[ "$login" == 200 || "$login" == 204 ]] || { echo "WebUI login failed after restart" >&2; exit 1; }
curl --noproxy '*' -fsS -b "$COOKIE" --get \
  --data-urlencode "hashes=$hash" "$WEBUI_V4/api/v2/torrents/info" > "$WORK_DIR/torrent-after-restart.json"
python3 - "$WORK_DIR/torrent-after-restart.json" "$hash" <<'PY'
import json
import sys
torrents = json.load(open(sys.argv[1], encoding="utf-8"))
assert len(torrents) == 1 and torrents[0]["hash"] == sys.argv[2], torrents
assert torrents[0]["name"] == "minttorrent-smoke-payload.bin", torrents[0]
assert torrents[0]["category"] == "minttorrent-smoke", torrents[0]
assert torrents[0]["tags"] == "minttorrent-smoke", torrents[0]
assert torrents[0]["state"].lower().startswith(("paused", "stopped")), torrents[0]
PY

curl --noproxy '*' -fsS -b "$COOKIE" -X POST \
  --data-urlencode "hashes=$hash" --data-urlencode deleteFiles=false \
  "$WEBUI_V4/api/v2/torrents/delete" > /dev/null
curl --noproxy '*' -fsS -b "$COOKIE" --get \
  --data-urlencode "hashes=$hash" "$WEBUI_V4/api/v2/torrents/info" > "$WORK_DIR/torrent-after-delete.json"
python3 - "$WORK_DIR/torrent-after-delete.json" <<'PY'
import json
import sys
assert json.load(open(sys.argv[1], encoding="utf-8")) == []
PY

MINTTORRENT_WEBUI_URL="$WEBUI_V4" MINTTORRENT_WEBUI_PASSWORD="$password" "$BUNDLE_DIR/bin/minttorrent" vpn status > "$WORK_DIR/cli-vpn.json"
MINTTORRENT_WEBUI_URL="$WEBUI_V4" MINTTORRENT_WEBUI_PASSWORD="$password" "$BUNDLE_DIR/bin/minttorrent" vpn disconnect
MINTTORRENT_WEBUI_URL="$WEBUI_V4" MINTTORRENT_WEBUI_PASSWORD="$password" "$BUNDLE_DIR/bin/minttorrent" torrent list > "$WORK_DIR/cli-torrents.json"
MINTTORRENT_WEBUI_URL="$WEBUI_V4" MINTTORRENT_WEBUI_PASSWORD="$password" "$BUNDLE_DIR/bin/minttorrent" config show > "$WORK_DIR/cli-config.json"
python3 - "$WORK_DIR/cli-vpn.json" "$WORK_DIR/cli-torrents.json" "$WORK_DIR/cli-config.json" <<'PY'
import json
import sys
vpn, torrents, config = [json.load(open(path, encoding="utf-8")) for path in sys.argv[1:]]
assert vpn["active"] is False and vpn["configured"] is True, vpn
assert torrents == [], torrents
assert isinstance(config, dict), type(config)
assert config["runtime"]["webui_port"] > 0, config
assert config["runtime"]["vpn_autostart"] is False, config
assert config["runtime"]["download_path"].endswith("/profile/downloads"), config
PY

echo "PASS: MintTorrent $version; authenticated WebUI/API and CLI; VPN/Netstack validation; settings; torrent and tracker CRUD; peer blocklist; speed limits; metrics CSV; files/priority/category/tag/pause/resume/delete; clean torrent restoration after service restart; IPv4/IPv6 loopback :$WEBUI_PORT; no torrent tracker or peer traffic sent."
