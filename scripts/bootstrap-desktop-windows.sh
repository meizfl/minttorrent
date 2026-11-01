#!/usr/bin/env bash
# Provision the existing Linux -> Windows desktop cross-build from public sources.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
BUILD="${MINTTORRENT_DESKTOP_BUILD_ROOT:-$ROOT/build/desktop-windows}"
NATIVE="$BUILD/native"
SOURCES="$ROOT/build/windows-sources"
JOBS="${MINTTORRENT_BUILD_JOBS:-4}"
for tool in curl python3 cmake ninja make perl x86_64-w64-mingw32-gcc x86_64-w64-mingw32-g++; do
  command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done
[[ -f /usr/include/boost/version.hpp && -d /usr/include/vulkan && -d /usr/include/vk_video ]] || {
  echo 'Install libboost-dev and libvulkan-dev before bootstrapping.' >&2; exit 1;
}
mkdir -p "$BUILD" "$NATIVE/include" "$SOURCES"
if [[ ! -x "$ROOT/build/desktop-tools/bin/aqt" ]]; then
  python3 -m venv "$ROOT/build/desktop-tools"
  "$ROOT/build/desktop-tools/bin/pip" install 'aqtinstall==3.3.0'
fi
AQT="$ROOT/build/desktop-tools/bin/aqt"
[[ -d "$ROOT/build/windows-qt/6.8.3/mingw_64" ]] || "$AQT" install-qt windows desktop 6.8.3 win64_mingw -O "$ROOT/build/windows-qt"
[[ -d "$ROOT/build/windows-qt-host/6.8.3/gcc_64" ]] || "$AQT" install-qt linux desktop 6.8.3 linux_gcc_64 -O "$ROOT/build/windows-qt-host"
fetch() {
  local url="$1" output="$2" digest="$3"
  if [[ ! -f "$output" ]]; then curl -fL --retry 3 "$url" -o "$output"; fi
  printf '%s  %s\n' "$digest" "$output" | sha256sum -c -
}
fetch https://www.openssl.org/source/openssl-3.0.16.tar.gz "$SOURCES/openssl-3.0.16.tar.gz" 57e03c50feab5d31b152af2b764f10379aecd8ee92f16c985983ce4a99f7ef86
fetch https://zlib.net/fossils/zlib-1.3.1.tar.gz "$SOURCES/zlib-1.3.1.tar.gz" 9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23
if [[ ! -f "$NATIVE/lib/libssl.dll.a" ]]; then
  tar -xf "$SOURCES/openssl-3.0.16.tar.gz" -C "$SOURCES"
  (
    cd "$SOURCES/openssl-3.0.16"
    CC=gcc CXX=g++ ./Configure mingw64 --cross-compile-prefix=x86_64-w64-mingw32- shared no-tests --prefix="$NATIVE" --libdir=lib
    make -j"$JOBS"
    make install_sw
  )
fi
if [[ ! -f "$NATIVE/lib/libzlib.dll.a" ]]; then
  tar -xf "$SOURCES/zlib-1.3.1.tar.gz" -C "$SOURCES"
  cmake -S "$SOURCES/zlib-1.3.1" -B "$BUILD/zlib" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$ROOT/cmake/toolchains/windows-mingw64.cmake" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$NATIVE"
  cmake --build "$BUILD/zlib" --parallel "$JOBS"
  cmake --install "$BUILD/zlib"
fi
# Copy only portable headers, never host C/C++ system include directories.
cp -a /usr/include/boost /usr/include/vulkan /usr/include/vk_video "$NATIVE/include/"
python3 - "$NATIVE" <<'PY'
from pathlib import Path
import re, sys
native=Path(sys.argv[1])
number=int(re.search(r'^#define BOOST_VERSION (\d+)',(native/'include/boost/version.hpp').read_text(),re.M).group(1))
version=f'{number//100000}.{number//100%1000}.{number%100}'
config=native/'lib/cmake'/f'Boost-{version}'
config.mkdir(parents=True,exist_ok=True)
(config/'BoostConfig.cmake').write_text(f'''set(Boost_VERSION {version})
set(Boost_MAJOR_VERSION {number//100000})
set(Boost_MINOR_VERSION {number//100%1000})
set(Boost_FOUND TRUE)
if(NOT TARGET Boost::headers)
  add_library(Boost::headers INTERFACE IMPORTED)
  get_filename_component(_boost_prefix "${{CMAKE_CURRENT_LIST_DIR}}/../../.." ABSOLUTE)
  set_target_properties(Boost::headers PROPERTIES INTERFACE_INCLUDE_DIRECTORIES "${{_boost_prefix}}/include")
endif()
if(NOT TARGET Boost::boost)
  add_library(Boost::boost ALIAS Boost::headers)
endif()
''')
(config/'BoostConfigVersion.cmake').write_text(f'''set(PACKAGE_VERSION {version})
if(PACKAGE_VERSION VERSION_LESS PACKAGE_FIND_VERSION)
  set(PACKAGE_VERSION_COMPATIBLE FALSE)
else()
  set(PACKAGE_VERSION_COMPATIBLE TRUE)
endif()
if(PACKAGE_VERSION VERSION_EQUAL PACKAGE_FIND_VERSION)
  set(PACKAGE_VERSION_EXACT TRUE)
endif()
''')
PY
printf 'Windows dependencies ready in %s\n' "$NATIVE"
