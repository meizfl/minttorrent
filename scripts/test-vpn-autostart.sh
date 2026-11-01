#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if (($# < 1 || $# > 2)); then
  echo "Usage: $0 AWG_PROFILE [BUNDLE_DIR]" >&2
  exit 2
fi
PROFILE_SOURCE="$(cd -- "$(dirname -- "$1")" && pwd)/$(basename -- "$1")"
[[ -s "$PROFILE_SOURCE" ]] || { echo "AWG profile is missing or empty" >&2; exit 1; }
if (($# == 2)); then
  BUNDLE_DIR="$(cd -- "$2" && pwd)"
elif [[ -x "$ROOT_DIR/bin/minttorrent" ]]; then
  BUNDLE_DIR="$ROOT_DIR"
else
  BUNDLE_DIR="$ROOT_DIR/dist/MintTorrent-$(cat "$ROOT_DIR/VERSION")-$(uname -m)-unknown-linux-gnu"
fi
LAUNCHER="$BUNDLE_DIR/bin/minttorrent"
[[ -x "$LAUNCHER" ]] || { echo "Bundle launcher not found: $LAUNCHER" >&2; exit 1; }
WEBUI_PORT="$(python3 "$ROOT_DIR/scripts/choose-loopback-test-port.py")"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/minttorrent-vpn-autostart.XXXXXX")"
PROFILE="$WORK_DIR/profile"
LOG="$WORK_DIR/startup.log"
COOKIE="$WORK_DIR/cookie.txt"
cp -- "$PROFILE_SOURCE" "$WORK_DIR/awg.conf"
chmod 0600 "$WORK_DIR/awg.conf"
cat > "$WORK_DIR/config.toml" <<CONFIG
[vpn]
config = "$WORK_DIR/awg.conf"
autostart = true
[torrent]
webui_port = $WEBUI_PORT
listen_port = 0
[torrent.storage]
download_path = ""
CONFIG

export MINTTORRENT_PROFILE="$PROFILE" MINTTORRENT_CONFIG="$WORK_DIR/config.toml"
"$LAUNCHER" >"$LOG" 2>&1 &
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
  rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT INT TERM

BASE="http://127.0.0.1:$WEBUI_PORT"
for _ in {1..30}; do
  code="$(curl --noproxy '*' --connect-timeout 1 -sS -o /dev/null -w '%{http_code}' "$BASE/" 2>/dev/null || true)"
  [[ "$code" == 200 ]] && break
  kill -0 "$PID" 2>/dev/null || { echo "MintTorrent exited during startup; check the config and AWG profile" >&2; exit 1; }
  sleep 1
done
[[ "${code:-}" == 200 ]] || { echo "WebUI did not start on configured loopback port $WEBUI_PORT" >&2; exit 1; }
password="$(sed -nE '/temporary password|тимчасовий пароль/Is/.*: ([[:alnum:]]+).*/\1/p' "$LOG" | tail -n1)"
[[ -n "$password" ]] || { echo "First-run WebUI password was not emitted" >&2; exit 1; }
login="$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' -c "$COOKIE" \
  --data-urlencode username=admin --data-urlencode "password=$password" "$BASE/api/v2/auth/login")"
[[ "$login" == 200 || "$login" == 204 ]] || { echo "WebUI login failed" >&2; exit 1; }

for _ in {1..120}; do
  curl --noproxy '*' -fsS -b "$COOKIE" "$BASE/api/v2/app/minttorrentVpnStatus" > "$WORK_DIR/status.json" || true
  if python3 - "$WORK_DIR/status.json" <<'PY'
import json, sys
try: s = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception: raise SystemExit(1)
raise SystemExit(0 if s.get('enabled') and s.get('active') and s.get('data_path_healthy') and s.get('last_handshake_ns') else 1)
PY
  then break; fi
  sleep 1
done
python3 - "$WORK_DIR/status.json" "$WORK_DIR/awg.conf" <<'PY'
import json, os, stat, sys
s = json.load(open(sys.argv[1], encoding='utf-8'))
assert s.get('enabled') is True and s.get('active') is True, s
assert s.get('data_path_healthy') is True and s.get('last_handshake_ns'), s
assert s.get('tx_bytes', 0) > 0 and s.get('rx_bytes', 0) > 0, s
assert stat.S_IMODE(os.stat(s['profile_path']).st_mode) == 0o600, s['profile_path']
assert open(s['profile_path'], 'rb').read() == open(sys.argv[2], 'rb').read()
print('PASS: TOML autostart created the active profile, received an AWG handshake, and passed gVisor DNS+TCP health with tunnel traffic in both directions.')
PY
