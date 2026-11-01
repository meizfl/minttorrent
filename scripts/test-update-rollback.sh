#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
command -v unshare >/dev/null || { echo "unshare is required for the isolated updater rollback test" >&2; exit 1; }

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/minttorrent-update-rollback.XXXXXX")"
trap 'rm -rf -- "$WORK_DIR"' EXIT

APP_DIR="$WORK_DIR/opt/MintTorrent"
SERVICE_FILE="$WORK_DIR/systemd/minttorrent.service"
FAKE_BIN="$WORK_DIR/fake-bin"
STAGE="$WORK_DIR/stage"
BUNDLE_NAME="MintTorrent-test-x86_64-unknown-linux-gnu"
ARCHIVE="$WORK_DIR/$BUNDLE_NAME.tar.gz"
mkdir -p "$APP_DIR/bin" "$APP_DIR/lib" "$APP_DIR/webui/qbittorrent/private" \
    "$(dirname -- "$SERVICE_FILE")" "$FAKE_BIN" "$STAGE/$BUNDLE_NAME/bin" \
    "$STAGE/$BUNDLE_NAME/lib" "$STAGE/$BUNDLE_NAME/webui/qbittorrent/private" \
    "$STAGE/$BUNDLE_NAME/systemd"

cat > "$APP_DIR/bin/minttorrent" <<'OLD_LAUNCHER'
#!/usr/bin/env sh
echo MINTTORRENT_STABLE_VERSION
OLD_LAUNCHER
chmod 0755 "$APP_DIR/bin/minttorrent"
printf 'old qBittorrent\n' > "$APP_DIR/bin/qbittorrent-nox"
printf 'old cli\n' > "$APP_DIR/bin/minttorrent-cli"
chmod 0755 "$APP_DIR/bin/qbittorrent-nox" "$APP_DIR/bin/minttorrent-cli"
printf 'old library\n' > "$APP_DIR/lib/libtorrent-rasterbar.so.2.1.2"
printf 'old WebUI\n' > "$APP_DIR/webui/qbittorrent/private/index.html"
printf '[Service]\nExecStart=stable\n' > "$SERVICE_FILE"
cp "$SERVICE_FILE" "$WORK_DIR/service.expected"

cat > "$STAGE/$BUNDLE_NAME/bin/minttorrent" <<'NEW_LAUNCHER'
#!/usr/bin/env sh
echo MINTTORRENT_BROKEN_VERSION
NEW_LAUNCHER
chmod 0755 "$STAGE/$BUNDLE_NAME/bin/minttorrent"
printf 'new qBittorrent\n' > "$STAGE/$BUNDLE_NAME/bin/qbittorrent-nox"
printf 'new cli\n' > "$STAGE/$BUNDLE_NAME/bin/minttorrent-cli"
chmod 0755 "$STAGE/$BUNDLE_NAME/bin/qbittorrent-nox" "$STAGE/$BUNDLE_NAME/bin/minttorrent-cli"
printf 'new library\n' > "$STAGE/$BUNDLE_NAME/lib/libtorrent-rasterbar.so.2.1.2"
printf 'new WebUI\n' > "$STAGE/$BUNDLE_NAME/webui/qbittorrent/private/index.html"
printf '[Service]\nExecStart=broken\n' > "$STAGE/$BUNDLE_NAME/systemd/minttorrent.service"

tar --owner=0 --group=0 -czf "$ARCHIVE" -C "$STAGE" "$BUNDLE_NAME"
(cd "$WORK_DIR" && sha256sum "$(basename -- "$ARCHIVE")" > "$(basename -- "$ARCHIVE").sha256")

cat > "$FAKE_BIN/systemctl" <<'FAKE_SYSTEMCTL'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  stop|start|daemon-reload) exit 0 ;;
  is-active)
    if grep -q 'MINTTORRENT_BROKEN_VERSION' "$MINTTORRENT_APP_DIR/bin/minttorrent"; then
      exit 1
    fi
    exit 0
    ;;
  *) echo "unexpected fake systemctl command: $*" >&2; exit 99 ;;
esac
FAKE_SYSTEMCTL
chmod 0755 "$FAKE_BIN/systemctl"

set +e
MINTTORRENT_APP_DIR="$APP_DIR" \
MINTTORRENT_SERVICE_FILE="$SERVICE_FILE" \
MINTTORRENT_UPDATE_START_TIMEOUT=1 \
PATH="$FAKE_BIN:$PATH" \
unshare --user --map-root-user env \
  MINTTORRENT_APP_DIR="$APP_DIR" \
  MINTTORRENT_SERVICE_FILE="$SERVICE_FILE" \
  MINTTORRENT_UPDATE_START_TIMEOUT=1 \
  PATH="$FAKE_BIN:$PATH" \
  bash "$ROOT_DIR/update.sh" --bundle "$ARCHIVE" \
  > "$WORK_DIR/update.log" 2>&1
update_status=$?
set -e

if ((update_status == 0)); then
  echo "Updater unexpectedly accepted the broken service" >&2
  exit 1
fi
grep -q 'Update failed; previous MintTorrent version was restored.' "$WORK_DIR/update.log" || {
  cat "$WORK_DIR/update.log" >&2
  echo "Updater did not report rollback" >&2
  exit 1
}
grep -q 'MINTTORRENT_STABLE_VERSION' "$APP_DIR/bin/minttorrent" || {
  echo "Previous MintTorrent launcher was not restored" >&2
  exit 1
}
cmp -s "$WORK_DIR/service.expected" "$SERVICE_FILE" || {
  echo "Previous systemd unit was not restored" >&2
  exit 1
}
[[ ! -e "$WORK_DIR/opt/.minttorrent-rollback.$$" ]] || {
  echo "Updater left a rollback directory behind" >&2
  exit 1
}
if find "$WORK_DIR/opt" -maxdepth 1 -type d -name '.minttorrent-*' -print -quit | grep -q .; then
  echo "Updater left temporary state behind" >&2
  exit 1
fi

echo "PASS: failed service startup restored the previous app and unit in an isolated user namespace."
