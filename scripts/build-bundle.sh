#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
BUILD_ROOT="${MINTTORRENT_BUILD_ROOT:-$ROOT/target}"
ARCH="$(uname -m)-unknown-linux-gnu"
if [[ -n "${MINTTORRENT_BUNDLE_TAG:-}" ]]; then
  NAME="MintTorrent-${VERSION}-${ARCH}-${MINTTORRENT_BUNDLE_TAG}"
else
  NAME="MintTorrent-${VERSION}-${ARCH}"
fi
DIST_ROOT="${MINTTORRENT_DIST_DIR:-$ROOT/dist}"
mkdir -p "$DIST_ROOT"
STAGE="$DIST_ROOT/$NAME"

"$ROOT/scripts/build-libtorrent.sh"
"$ROOT/scripts/build-qbittorrent.sh"
"$ROOT/scripts/build-cli.sh"

QBT="$BUILD_ROOT/qbittorrent-nox-build/qbittorrent-nox"
QT_LIB_DIR="$(dirname -- "$(ldd "$QBT" | awk '/libQt6Core\.so/ {print $3; exit}')")"
PLUGIN_ROOT="${QT_LIB_DIR}/qt6/plugins"
if [[ ! -d "$PLUGIN_ROOT" ]]; then
  # Qt source installs use <prefix>/plugins, while distro packages commonly
  # place plugins under <libdir>/qt6/plugins.
  PLUGIN_ROOT="$(dirname -- "$QT_LIB_DIR")/plugins"
fi
[[ -d "$PLUGIN_ROOT" ]] || { echo "Qt plugin directory not found: $PLUGIN_ROOT" >&2; exit 1; }
rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/lib" "$STAGE/plugins" "$STAGE/config/vpn" "$STAGE/systemd" "$STAGE/webui" "$STAGE/licenses" "$STAGE/docs" "$STAGE/scripts"
install -m 0755 "$QBT" "$STAGE/bin/qbittorrent-nox"
install -m 0755 "$BUILD_ROOT/native/bin/minttorrent-cli" "$STAGE/bin/minttorrent-cli"
cp -a "$BUILD_ROOT/native/lib/libtorrent-rasterbar.so"* "$STAGE/lib/"
cp -a "$BUILD_ROOT/native/lib/libminttorrent_awg.so" "$STAGE/lib/"
chmod 0755 "$STAGE"/lib/*.so*

# Keep the Qt SQL and TLS backends beside the binary so qBittorrent does not
# depend on the target machine having the same Qt plugin installation.
for plugin in sqldrivers/libqsqlite.so tls/libqopensslbackend.so; do
  if [[ -f "$PLUGIN_ROOT/$plugin" ]]; then
    mkdir -p "$STAGE/plugins/$(dirname "$plugin")"
    install -m 0755 "$PLUGIN_ROOT/$plugin" "$STAGE/plugins/$plugin"
  fi
done

runtime_elfs=("$STAGE/bin/qbittorrent-nox" "$STAGE/lib/libtorrent-rasterbar.so.2.1.2" "$STAGE/lib/libminttorrent_awg.so")
while IFS= read -r -d '' plugin; do runtime_elfs+=("$plugin"); done < <(find "$STAGE/plugins" -type f -print0)
runtime_deps=""
for elf in "${runtime_elfs[@]}"; do runtime_deps+="$(ldd "$elf")"$'\n'; done
runtime_deps="$(printf '%s\n' "$runtime_deps" | awk '$2 == "=>" && $3 ~ /^\// {print $3} $1 ~ /^\// {print $1}' | sort -u)"
while IFS= read -r dependency; do
  [[ -n "$dependency" ]] || continue
  name="$(basename -- "$dependency")"
  case "$name" in libc.so.*|ld-linux*.so.*|libm.so.*|libpthread.so.*|librt.so.*|libdl.so.*|libresolv.so.*) continue ;; esac
  soname="$(readelf -d "$dependency" 2>/dev/null | sed -n 's/.*(SONAME).*\[\([^]]*\)\].*/\1/p' | head -n 1)"
  [[ -n "$soname" ]] || soname="$name"
  [[ -e "$STAGE/lib/$soname" ]] || install -m 0755 "$dependency" "$STAGE/lib/$soname"
done <<< "$runtime_deps"

for elf in "${runtime_elfs[@]}"; do
  if env LD_LIBRARY_PATH="$STAGE/lib" ldd "$elf" | grep -q 'not found'; then
    echo "Unresolved runtime dependency in $elf" >&2; exit 1
  fi
done

if [[ -n "${MINTTORRENT_MAX_GLIBC:-}" ]]; then
  python3 "$ROOT/scripts/check-glibc-requirements.py" "$STAGE" "$MINTTORRENT_MAX_GLIBC"
fi

install -m 0755 "$ROOT/scripts/minttorrent-launcher.sh" "$STAGE/bin/minttorrent"

cp "$ROOT/systemd/minttorrent.service" "$STAGE/systemd/minttorrent.service"
cp "$ROOT/install.sh" "$ROOT/uninstall.sh" "$ROOT/update.sh" "$ROOT/README.md" "$ROOT/LICENSE" "$STAGE/"
cp -a "$ROOT/vendor/qbittorrent/src/webui/www" "$STAGE/webui/qbittorrent"
cat > "$STAGE/webui/qbittorrent/UPSTREAM.md" <<'WEBUI'
# Bundled qBittorrent WebUI

These static resources are shipped from the same qBittorrent 5.3.0 source tree
used to build `bin/qbittorrent-nox` (baseline commit
`9213075dd5f7b352208361c6a84c1c115efc898e`, with MintTorrent branding and
settings patches). The C++ server embeds these resources; this copy is for
inspection and offline access and is not a separate runtime UI.

The upstream resources are GPL-3.0-or-later. See `../licenses/qBittorrent-COPYING`.
WEBUI
cp "$ROOT/config/vpn/README.md" "$ROOT/config/vpn/default.conf.example" "$STAGE/config/vpn/"
cat > "$STAGE/config/vpn/default.conf" <<'VPNEMPTY'
# MintTorrent public release: no VPN credentials are bundled.
# Import your own AmneziaWG profile through Settings > AmneziaWG or the CLI.
VPNEMPTY
chmod 0600 "$STAGE/config/vpn/default.conf"
install -m 0644 "$ROOT/config/config.toml.example" "$STAGE/config/config.toml"
install -m 0644 "$ROOT/config/config.toml.example" "$STAGE/config/config.toml.example"
cp "$ROOT/docs/acceptance-matrix.md" "$ROOT/docs/architecture.md" "$ROOT/docs/project-status.md" "$STAGE/docs/"
install -m 0755 "$ROOT/scripts/smoke-bundle.sh" "$ROOT/scripts/audit-network-syscalls.sh" "$ROOT/scripts/test-vpn-autostart.sh" "$ROOT/scripts/test-torrent-over-vpn.sh" "$ROOT/scripts/test-network-packet-capture.sh" "$ROOT/scripts/verify-packet-capture.py" "$ROOT/scripts/sample-qbittorrent-metrics.py" "$ROOT/scripts/test-cli.sh" "$ROOT/scripts/test-update-validation.sh" "$ROOT/scripts/test-update-rollback.sh" "$ROOT/scripts/test-update-preservation.sh" "$ROOT/scripts/test-qbittorrent-host-interface-isolation.sh" "$ROOT/scripts/choose-loopback-test-port.py" "$ROOT/scripts/udp-underlay-relay.py" "$STAGE/scripts/"
cp "$ROOT/vendor/qbittorrent/COPYING" "$STAGE/licenses/qBittorrent-COPYING"
cp "$ROOT/vendor/libtorrent/COPYING" "$STAGE/licenses/libtorrent-COPYING"
cp "$ROOT/components/amneziawg-go/LICENSE" "$STAGE/licenses/amneziawg-go-LICENSE"
cp "$ROOT/licenses/Go-LICENSE" "$STAGE/licenses/Go-LICENSE"
cp "$ROOT/licenses/x-term-LICENSE.txt" "$ROOT/licenses/x-sys-LICENSE.txt" "$STAGE/licenses/"
cp "$ROOT/licenses/THIRD-PARTY.md" "$STAGE/licenses/THIRD-PARTY.md"
cp -a "$ROOT/licenses/runtime" "$STAGE/licenses/"

cat > "$STAGE/RUNTIME-DEPENDENCIES.txt" <<'DEPENDENCIES'
MintTorrent runs the C++ qBittorrent nox server with the patched libtorrent v2
transport and the in-process AmneziaWG-Go/gVisor bridge. Its Go API CLI is a
standalone binary. Qt runtime libraries,
OpenSSL, compression libraries, and required Qt SQL/TLS plugins are bundled.
A compatible Linux kernel, glibc, ELF loader, and system CA certificates remain
provided by the target system. No Rust executable is part of the runtime.
DEPENDENCIES

cat > "$STAGE/BUNDLE-STATUS.txt" <<STATUS
MintTorrent $VERSION ($ARCH)
Build target: ${MINTTORRENT_BUILD_TARGET_LABEL:-native Linux build}
Runtime: qBittorrent 5.x C++ nox server and its original WebUI/API, patched
libtorrent v2 userspace socket facade, AmneziaWG-Go, and gVisor Netstack.
WebUI defaults to 127.0.0.1:4101 and [::1]:4101. The BitTorrent port is chosen
once per process start from 10000-65535. UPnP, NAT-PMP, LSD and external torrent
proxies are disabled. BitTorrent sockets fail closed without an active gVisor
stack; the encrypted AmneziaWG UDP endpoint is the only host-network transport.
Settings contain separate gVisor Netstack and AmneziaWG profile tabs. Search
plugins and Qt HTTP helpers cannot fall back to host network sockets. SMTP
notifications and peer reverse-DNS lookups are disabled in this build because
their upstream code uses direct host networking/resolution.
Run ./bin/minttorrent. The first-run WebUI administrator password is printed
to the console or service journal. qBittorrent settings are stored in its
profile directory. Edit config/config.toml before starting the bundle to set
the WebUI/P2P ports, download path, VPN profile source, and VPN autostart. Port
0 selects one random P2P port from 10000-65535 on each start. The installed
service reads /etc/minttorrent/config.toml, created once and preserved across
updates. An empty download_path means <profile>/downloads. Settings -> Downloads
shows the exact effective path.
The launcher provides authenticated VPN, torrent, and configuration CLI
subcommands through the bundled standalone minttorrent-cli binary.
STATUS

tar -C "$DIST_ROOT" -czf "$DIST_ROOT/$NAME.tar.gz" "$NAME"
(cd "$DIST_ROOT" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256")
echo "Created $DIST_ROOT/$NAME.tar.gz"
