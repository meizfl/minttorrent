#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
command -v unshare >/dev/null || { echo "unshare is required for the isolated updater test" >&2; exit 1; }

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/minttorrent-update-preservation.XXXXXX")"
trap 'rm -rf -- "$WORK_DIR"' EXIT

APP_DIR="$WORK_DIR/opt/MintTorrent"
SERVICE_FILE="$WORK_DIR/systemd/minttorrent.service"
FAKE_BIN="$WORK_DIR/fake-bin"
STAGE="$WORK_DIR/stage"
BUNDLE_NAME="MintTorrent-test-x86_64-unknown-linux-gnu"
ARCHIVE="$WORK_DIR/$BUNDLE_NAME.tar.gz"
CONFIG="$WORK_DIR/etc/minttorrent/config.toml"
PROFILE="$WORK_DIR/var/lib/minttorrent/profile/qBittorrent.ini"
DOWNLOAD="$WORK_DIR/var/lib/minttorrent/profile/downloads/operator-data.bin"

mkdir -p "$APP_DIR/bin" "$APP_DIR/lib" "$APP_DIR/webui/qbittorrent/private" \
  "$(dirname -- "$SERVICE_FILE")" "$FAKE_BIN" "$STAGE/$BUNDLE_NAME/bin" \
  "$STAGE/$BUNDLE_NAME/lib" "$STAGE/$BUNDLE_NAME/webui/qbittorrent/private" \
  "$STAGE/$BUNDLE_NAME/systemd" "$(dirname -- "$CONFIG")" \
  "$(dirname -- "$PROFILE")" "$(dirname -- "$DOWNLOAD")"

cat > "$APP_DIR/bin/minttorrent" <<'OLD_LAUNCHER'
#!/usr/bin/env sh
echo MINTTORRENT_OLD_VERSION
OLD_LAUNCHER
chmod 0755 "$APP_DIR/bin/minttorrent"
printf 'old qBittorrent\n' > "$APP_DIR/bin/qbittorrent-nox"
printf 'old cli\n' > "$APP_DIR/bin/minttorrent-cli"
chmod 0755 "$APP_DIR/bin/qbittorrent-nox" "$APP_DIR/bin/minttorrent-cli"
printf 'old library\n' > "$APP_DIR/lib/libtorrent-rasterbar.so.2.1.2"
printf 'old WebUI\n' > "$APP_DIR/webui/qbittorrent/private/index.html"
printf '[Service]\nExecStart=old\n' > "$SERVICE_FILE"

cat > "$STAGE/$BUNDLE_NAME/bin/minttorrent" <<'NEW_LAUNCHER'
#!/usr/bin/env sh
echo MINTTORRENT_NEW_VERSION
NEW_LAUNCHER
chmod 0755 "$STAGE/$BUNDLE_NAME/bin/minttorrent"
printf 'new qBittorrent\n' > "$STAGE/$BUNDLE_NAME/bin/qbittorrent-nox"
printf 'new cli\n' > "$STAGE/$BUNDLE_NAME/bin/minttorrent-cli"
chmod 0755 "$STAGE/$BUNDLE_NAME/bin/qbittorrent-nox" "$STAGE/$BUNDLE_NAME/bin/minttorrent-cli"
printf 'new library\n' > "$STAGE/$BUNDLE_NAME/lib/libtorrent-rasterbar.so.2.1.2"
printf 'new WebUI\n' > "$STAGE/$BUNDLE_NAME/webui/qbittorrent/private/index.html"
printf '[Service]\nExecStart=new\n' > "$STAGE/$BUNDLE_NAME/systemd/minttorrent.service"

printf 'operator config must survive updates\n' > "$CONFIG"
printf 'operator profile must survive updates\n' > "$PROFILE"
printf 'user download must survive updates\n' > "$DOWNLOAD"
cp "$CONFIG" "$WORK_DIR/config.expected"
cp "$PROFILE" "$WORK_DIR/profile.expected"
cp "$DOWNLOAD" "$WORK_DIR/download.expected"

tar --owner=0 --group=0 -czf "$ARCHIVE" -C "$STAGE" "$BUNDLE_NAME"
(cd "$WORK_DIR" && sha256sum "$(basename -- "$ARCHIVE")" > "$(basename -- "$ARCHIVE").sha256")

cat > "$FAKE_BIN/systemctl" <<'FAKE_SYSTEMCTL'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  stop|start|daemon-reload) exit 0 ;;
  is-active) exit 0 ;;
  *) echo "unexpected fake systemctl command: $*" >&2; exit 99 ;;
esac
FAKE_SYSTEMCTL
chmod 0755 "$FAKE_BIN/systemctl"

unshare --user --map-root-user env \
  MINTTORRENT_APP_DIR="$APP_DIR" \
  MINTTORRENT_SERVICE_FILE="$SERVICE_FILE" \
  MINTTORRENT_UPDATE_START_TIMEOUT=1 \
  PATH="$FAKE_BIN:$PATH" \
  bash "$ROOT_DIR/update.sh" --bundle "$ARCHIVE" > "$WORK_DIR/update.log" 2>&1 || {
    cat "$WORK_DIR/update.log" >&2
    exit 1
  }

grep -q 'MINTTORRENT_NEW_VERSION' "$APP_DIR/bin/minttorrent" || {
  echo "New MintTorrent launcher was not installed" >&2
  exit 1
}
grep -q 'ExecStart=new' "$SERVICE_FILE" || {
  echo "New systemd unit was not installed" >&2
  exit 1
}
cmp -s "$WORK_DIR/config.expected" "$CONFIG" || { echo "Operator config was changed by update" >&2; exit 1; }
cmp -s "$WORK_DIR/profile.expected" "$PROFILE" || { echo "qBittorrent profile was changed by update" >&2; exit 1; }
cmp -s "$WORK_DIR/download.expected" "$DOWNLOAD" || { echo "User downloads were changed by update" >&2; exit 1; }
if find "$WORK_DIR/opt" -maxdepth 1 -type d -name '.minttorrent-*' -print -quit | grep -q .; then
  echo "Updater left transaction state behind" >&2
  exit 1
fi

echo "PASS: successful update installed the new app/unit and preserved operator config, qBittorrent profile, and downloads."
