#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/minttorrent-cli-test.XXXXXX")"
trap 'rm -rf -- "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/mock" "$WORK_DIR/profile"
LAUNCHER_SOURCE="$ROOT_DIR/scripts/minttorrent-launcher.sh"
[[ -f "$LAUNCHER_SOURCE" ]] || LAUNCHER_SOURCE="$ROOT_DIR/bin/minttorrent"
install -m 0755 "$LAUNCHER_SOURCE" "$WORK_DIR/bin/minttorrent"
cat > "$WORK_DIR/mock/systemctl" <<'MOCK'
#!/usr/bin/env sh
printf 'systemctl'
printf ' <%s>' "$@"
MOCK
cat > "$WORK_DIR/mock/journalctl" <<'MOCK'
#!/usr/bin/env sh
printf 'journalctl'
printf ' <%s>' "$@"
MOCK
cat > "$WORK_DIR/bin/qbittorrent-nox" <<'MOCK'
#!/usr/bin/env sh
printf 'qbittorrent'
printf ' <%s>' "$@"
MOCK
cat > "$WORK_DIR/bin/minttorrent-cli" <<'MOCK'
#!/usr/bin/env sh
printf 'minttorrent-cli'
printf ' <%s>' "$@"
MOCK
chmod 0755 "$WORK_DIR/mock/systemctl" "$WORK_DIR/mock/journalctl" "$WORK_DIR/bin/qbittorrent-nox" "$WORK_DIR/bin/minttorrent-cli"

export MINTTORRENT_PROFILE="$WORK_DIR/profile"
export PATH="$WORK_DIR/mock:$PATH"

assert_command() {
  local expected="$1"
  shift
  local actual
  actual="$("$WORK_DIR/bin/minttorrent" "$@")"
  [[ "$actual" == "$expected" ]] || {
    printf 'FAIL: minttorrent %s\n expected: %s\n   actual: %s\n' "$*" "$expected" "$actual" >&2
    exit 1
  }
}

assert_command 'systemctl <start> <minttorrent.service>' start
assert_command 'systemctl <stop> <minttorrent.service>' stop
assert_command 'systemctl <restart> <minttorrent.service>' restart
assert_command 'systemctl <--no-pager> <status> <minttorrent.service>' status
assert_command 'journalctl <-u> <minttorrent.service> <-f> <--since=5m>' logs --since=5m
assert_command 'minttorrent-cli <vpn> <status>' vpn status
assert_command 'minttorrent-cli <torrent> <list>' torrent list
assert_command 'minttorrent-cli <config> <show>' config show
assert_command "minttorrent-cli <__launch> <$WORK_DIR/bin/qbittorrent-nox> <$WORK_DIR/profile> <$WORK_DIR/bin/../config/config.toml> <-->" 
assert_command "minttorrent-cli <__launch> <$WORK_DIR/bin/qbittorrent-nox> <$WORK_DIR/profile> <$WORK_DIR/bin/../config/config.toml> <--> <--webui-port=4101>" run --webui-port=4101
assert_command "minttorrent-cli <__launch> <$WORK_DIR/bin/qbittorrent-nox> <$WORK_DIR/profile> <$WORK_DIR/bin/../config/config.toml> <--> <--version>" --version

if "$WORK_DIR/bin/minttorrent" start extra >/dev/null 2>&1; then
  echo 'FAIL: start accepted unexpected arguments' >&2
  exit 1
fi

echo 'PASS: lifecycle, logs, foreground run, and qBittorrent argument forwarding.'
