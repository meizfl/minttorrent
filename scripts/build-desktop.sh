#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
PLATFORM="${1:-linux}"
BUILD="${MINTTORRENT_DESKTOP_BUILD_ROOT:-$ROOT/build/desktop-$PLATFORM}"
JOBS="${MINTTORRENT_BUILD_JOBS:-4}"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
mkdir -p "$BUILD/native/lib" "$BUILD/go-cache"
if [[ "$PLATFORM" == linux ]]; then
  MINTTORRENT_BUILD_ROOT="$BUILD" "$ROOT/scripts/build-libtorrent.sh"
  OPTIONS=(-DCMAKE_PREFIX_PATH="$BUILD/native" -DDBUS=OFF -DSYSTEMD=OFF)
elif [[ "$PLATFORM" == windows ]]; then
  : "${MINTTORRENT_QT_WINDOWS:=$ROOT/build/windows-qt/6.8.3/mingw_64}"
  : "${MINTTORRENT_QT_HOST:=$ROOT/build/windows-qt-host/6.8.3/gcc_64}"
  [[ -f "$BUILD/native/lib/libssl.dll.a" ]] || { echo 'Build OpenSSL, zlib and provide Boost headers in the Windows native prefix first (docs/desktop-builds.md).' >&2; exit 1; }
  (
    cd "$ROOT/components/awgnet"
    GOOS=windows GOARCH=amd64 CGO_ENABLED=1 CC=x86_64-w64-mingw32-gcc CXX=x86_64-w64-mingw32-g++ GOCACHE="$BUILD/go-cache" \
      go build -buildvcs=false -trimpath -buildmode=c-archive -o "$BUILD/native/lib/libminttorrent_awg.a" .
  )
  TOOLCHAIN="$ROOT/cmake/toolchains/windows-mingw64.cmake"
  cmake -S "$ROOT/vendor/libtorrent" -B "$BUILD/libtorrent" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$BUILD/native" -DCMAKE_PREFIX_PATH="$BUILD/native" \
    -DOPENSSL_ROOT_DIR="$BUILD/native" -Dbuild_tests=OFF -Ddeprecated-functions=OFF \
    -Dpython-bindings=OFF -Dwebtorrent=OFF -Dminttorrent_netstack=ON \
    -DMINTTORRENT_AWG_LIBRARY="$BUILD/native/lib/libminttorrent_awg.a"
  cmake --build "$BUILD/libtorrent" --parallel "$JOBS"
  cmake --install "$BUILD/libtorrent"
  OPTIONS=(-DVulkan_INCLUDE_DIR="$BUILD/native/include" -UOpenSSL_DIR -DCMAKE_FIND_ROOT_PATH="$BUILD/native;$MINTTORRENT_QT_WINDOWS" -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" -DCMAKE_PREFIX_PATH="$BUILD/native;$MINTTORRENT_QT_WINDOWS" -DOPENSSL_ROOT_DIR="$BUILD/native" -DQT_HOST_PATH="$MINTTORRENT_QT_HOST")
else
  echo "Usage: $0 linux|windows" >&2; exit 1
fi
cmake -S "$ROOT/vendor/qbittorrent" -B "$BUILD/qbittorrent" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DMINTTORRENT_VERSION="$VERSION" \
  -DGUI=ON -DWEBUI=ON -DPLUGINS=ON -DSTACKTRACE=OFF "${OPTIONS[@]}"
cmake --build "$BUILD/qbittorrent" --parallel "$JOBS"
SUFFIX=""
[[ "$PLATFORM" != windows ]] || SUFFIX=.exe
printf 'Built desktop client: %s\n' "$BUILD/qbittorrent/qbittorrent$SUFFIX"
