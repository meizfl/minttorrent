#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then echo "Run this installer as root: sudo ./install.sh" >&2; exit 1; fi
if ! command -v systemctl >/dev/null || [[ ! -d /run/systemd/system ]]; then echo "systemd is required" >&2; exit 1; fi

enable_service=ask
start_service=0
while (($#)); do
  case "$1" in
    --enable) enable_service=yes; start_service=0 ;;
    --enable-and-start) enable_service=yes; start_service=1 ;;
    --no-enable) enable_service=no; start_service=0 ;;
    *) echo "Usage: $0 [--enable|--enable-and-start|--no-enable]" >&2; exit 2 ;;
  esac
  shift
done

SOURCE_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
[[ -x "$SOURCE_DIR/bin/qbittorrent-nox" && -x "$SOURCE_DIR/bin/minttorrent" \
   && -x "$SOURCE_DIR/bin/minttorrent-cli" \
   && -d "$SOURCE_DIR/lib" && -d "$SOURCE_DIR/plugins" \
   && -d "$SOURCE_DIR/licenses" && -d "$SOURCE_DIR/docs" \
   && -d "$SOURCE_DIR/config/vpn" \
   && -f "$SOURCE_DIR/systemd/minttorrent.service" \
   && -f "$SOURCE_DIR/LICENSE" && -f "$SOURCE_DIR/README.md" \
   && -f "$SOURCE_DIR/BUNDLE-STATUS.txt" ]] || {
  echo "Run install.sh from the unpacked standalone bundle, not from the source tree" >&2
  exit 1
}
[[ -f "$SOURCE_DIR/lib/libtorrent-rasterbar.so.2.1.2" && -f "$SOURCE_DIR/lib/libminttorrent_awg.so" ]] || {
  echo "The standalone bundle is missing the patched libtorrent or AmneziaWG runtime" >&2
  exit 1
}
BINARY="$SOURCE_DIR/bin/qbittorrent-nox"
APP_DIR=/opt/MintTorrent
DATA_DIR=/var/lib/minttorrent
COMMAND_LINK=/usr/local/bin/minttorrent
if [[ -e "$COMMAND_LINK" && "$(readlink -f -- "$COMMAND_LINK")" != "$APP_DIR/bin/minttorrent" ]]; then echo "Refusing to replace existing command: $COMMAND_LINK" >&2; exit 1; fi
if ! id minttorrent >/dev/null 2>&1; then useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin minttorrent; fi

install -d -o root -g root -m 0755 "$APP_DIR" "$APP_DIR/bin" "$APP_DIR/lib" "$APP_DIR/plugins" "$(dirname -- "$COMMAND_LINK")"
install -d -o root -g root -m 0755 "$APP_DIR/licenses" "$APP_DIR/docs" "$APP_DIR/config/vpn" /etc/minttorrent /etc/minttorrent/vpn
install -d -o minttorrent -g minttorrent -m 0750 "$DATA_DIR" "$DATA_DIR/profile" "$DATA_DIR/profile/downloads" "$DATA_DIR/incomplete"
install -d -o minttorrent -g minttorrent -m 0750 /var/log/minttorrent
if [[ ! -e /etc/minttorrent/config.toml ]]; then install -o root -g minttorrent -m 0640 "$SOURCE_DIR/config/config.toml" /etc/minttorrent/config.toml; fi
if [[ ! -e /etc/minttorrent/vpn/default.conf && -s "$SOURCE_DIR/config/vpn/default.conf" ]]; then
  install -o root -g minttorrent -m 0640 "$SOURCE_DIR/config/vpn/default.conf" /etc/minttorrent/vpn/default.conf
fi
install -m 0755 "$BINARY" "$APP_DIR/bin/qbittorrent-nox"
install -m 0755 "$SOURCE_DIR/bin/minttorrent-cli" "$APP_DIR/bin/minttorrent-cli"
NATIVE_LIB_DIR="$SOURCE_DIR/lib"
cp -a "$NATIVE_LIB_DIR"/*.so* "$APP_DIR/lib/"
cp -a "$SOURCE_DIR/plugins/." "$APP_DIR/plugins/"
install -m 0755 "$SOURCE_DIR/bin/minttorrent" "$APP_DIR/bin/minttorrent"
install -m 0755 "$SOURCE_DIR/update.sh" "$APP_DIR/update.sh"
install -m 0644 "$SOURCE_DIR/systemd/minttorrent.service" /etc/systemd/system/minttorrent.service
ln -sfn "$APP_DIR/bin/minttorrent" "$COMMAND_LINK"
if [[ -d "$SOURCE_DIR/webui/qbittorrent" ]]; then install -d -m 0755 "$APP_DIR/webui"; cp -a "$SOURCE_DIR/webui/qbittorrent" "$APP_DIR/webui/"; fi
cp -a "$SOURCE_DIR/licenses/." "$APP_DIR/licenses/"
cp -a "$SOURCE_DIR/docs/." "$APP_DIR/docs/"
cp -a "$SOURCE_DIR/config/vpn/." "$APP_DIR/config/vpn/"
install -m 0644 "$SOURCE_DIR/LICENSE" "$SOURCE_DIR/README.md" "$SOURCE_DIR/BUNDLE-STATUS.txt" "$APP_DIR/"
chown -R root:root "$APP_DIR"
chown -R minttorrent:minttorrent "$DATA_DIR"
systemctl daemon-reload
echo "Installed MintTorrent C++ qBittorrent nox, WebUI and userspace networking libraries."
if [[ "$enable_service" == ask && -t 0 ]]; then
  read -r -p "Enable MintTorrent at boot and start it now? [y/N] " answer
  case "$answer" in y|Y|yes|YES) enable_service=yes; start_service=1 ;; *) enable_service=no ;; esac
fi
if [[ "$enable_service" == yes ]]; then
  systemctl enable minttorrent.service
  if ((start_service)); then systemctl start minttorrent.service; fi
else
  echo "Service was installed but not enabled. Enable it with: systemctl enable --now minttorrent.service"
fi
