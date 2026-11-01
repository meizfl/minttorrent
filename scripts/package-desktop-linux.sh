#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
BUILD="${MINTTORRENT_DESKTOP_BUILD_ROOT:-$ROOT/build/desktop-linux}"
NATIVE="${MINTTORRENT_NATIVE_PREFIX:-$BUILD/native}"
QT_PLUGINS="${MINTTORRENT_QT_PLUGINS:-$(qmake6 -query QT_INSTALL_PLUGINS)}"
NAME="MintTorrent-$(cat "$ROOT/VERSION")-desktop-linux-x86_64${MINTTORRENT_BUNDLE_TAG:+-$MINTTORRENT_BUNDLE_TAG}"
DIST="${MINTTORRENT_DIST_DIR:-$ROOT/dist}"
STAGE="$DIST/$NAME"
[[ -x "$BUILD/qbittorrent/qbittorrent" ]] || { echo 'Build the desktop client first' >&2; exit 1; }
mkdir -p "$STAGE/bin" "$STAGE/lib" "$STAGE/plugins" "$STAGE/licenses"
# Remove obsolete launchers from earlier packaging runs.
rm -f "$STAGE/MintTorrent.sh" "$STAGE/MintTorrent.desktop" "$STAGE/bin/minttorrent-desktop" "$STAGE/bin/qt.conf"
install -m755 "$BUILD/qbittorrent/qbittorrent" "$STAGE/MintTorrent"
cp -a "$NATIVE/lib/"libtorrent-rasterbar.so* "$NATIVE/lib/libminttorrent_awg.so" "$STAGE/lib/"
for group in platforms platforminputcontexts platformthemes imageformats iconengines xcbglintegrations wayland-graphics-integration-client wayland-decoration-client wayland-shell-integration tls sqldrivers; do
  [[ ! -d "$QT_PLUGINS/$group" ]] || cp -a "$QT_PLUGINS/$group" "$STAGE/plugins/"
done
# ldd includes transitive dependencies of the executable and dynamically loaded plugins.
while IFS= read -r dependency; do
  name="$(basename -- "$dependency")"
  case "$name" in libc.so.*|ld-linux*.so.*|libm.so.*|libpthread.so.*|librt.so.*|libdl.so.*|libresolv.so.*) continue ;; esac
  [[ -e "$STAGE/lib/$name" ]] || cp -L "$dependency" "$STAGE/lib/$name"
done < <(find "$STAGE/MintTorrent" "$STAGE/lib" "$STAGE/plugins" -type f -print0 | xargs -0 -r ldd 2>/dev/null | awk '$2 == "=>" && $3 ~ /^\// {print $3}' | sort -u)
cat > "$STAGE/qt.conf" <<'QTCONF'
[Paths]
Prefix=.
Plugins=plugins
QTCONF
rmdir "$STAGE/bin" 2>/dev/null || true
cp "$ROOT/vendor/qbittorrent/src/webui/www/public/images/minttorrent-logo.svg" "$STAGE/minttorrent.svg"
cp "$ROOT/LICENSE" "$STAGE/"
cp "$ROOT/vendor/qbittorrent/COPYING" "$STAGE/licenses/qBittorrent-COPYING"
cp "$ROOT/vendor/libtorrent/COPYING" "$STAGE/licenses/libtorrent-COPYING"
cp "$ROOT/components/amneziawg-go/LICENSE" "$STAGE/licenses/amneziawg-go-LICENSE"
cp -a "$ROOT/licenses/runtime" "$STAGE/licenses/"
cat > "$STAGE/README.txt" <<'README'
Run ./MintTorrent from an extracted directory. This is the desktop ELF binary; no shell launcher is required.
Open Preferences > AmneziaWG, import your .conf and click Save profile and connect.
Preferences > gVisor Netstack configures IP families, MTU, queue and TCP buffers.
No VPN credentials are included. Torrent traffic is blocked until VPN is connected.
Imported VPN and torrent state use the MintTorrent user profile, separate from qBittorrent.
This native Linux build requires a host glibc at least as new as GLIBC-REQUIREMENTS.txt.
The system provides the display server, graphics drivers, fonts and CA certificates.
README
python3 - "$STAGE" > "$STAGE/GLIBC-REQUIREMENTS.txt" <<'PYGLIBC'
from pathlib import Path
import re, subprocess, sys
versions = []
for p in Path(sys.argv[1]).rglob('*'):
    if p.is_file() and p.open('rb').read(4) == b'\x7fELF':
        text = subprocess.check_output(['readelf', '--version-info', str(p)], text=True)
        versions.extend(tuple(map(int, v.split('.'))) for v in re.findall(r'GLIBC_([0-9.]+)', text))
print('Required host glibc: ' + '.'.join(map(str, max(versions))))
PYGLIBC
for module in qt6-base qt6-svg; do
  [[ ! -L "$STAGE/licenses/$module" ]] || rm "$STAGE/licenses/$module"
  [[ ! -d /usr/share/licenses/$module ]] || cp -aL /usr/share/licenses/$module "$STAGE/licenses/"
done
if [[ -n "${MINTTORRENT_MAX_GLIBC:-}" ]]; then
  python3 "$ROOT/scripts/check-glibc-requirements.py" "$STAGE" "$MINTTORRENT_MAX_GLIBC"
fi
(cd "$STAGE" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
tar -C "$DIST" -czf "$DIST/$NAME.tar.gz" "$NAME"
(cd "$DIST" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256")
echo "$DIST/$NAME.tar.gz"
