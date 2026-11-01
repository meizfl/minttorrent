# MintTorrent desktop builds

Desktop targets compile the vendored qBittorrent GUI with the existing MintTorrent
libtorrent socket adapters, AmneziaWG-Go, gVisor and embedded WebUI. Native
preferences add gVisor Netstack and AmneziaWG pages. The main window and About
identify MintTorrent; protocol peer ID remains `-qB5300-`.

## Linux x86_64

```
./scripts/build-desktop.sh linux
./scripts/package-desktop-linux.sh
```

The desktop build uses its own `build/desktop-linux` directory. The package is
`dist/MintTorrent-0.1.0-desktop-linux-x86_64.tar.gz`; extract and run
`./MintTorrent`. The launcher is the desktop ELF executable, with a relative library search path; no shell script is shipped. Qt runtime libraries and display plugins are bundled. The
host supplies glibc, display server, graphics drivers, fonts and CA certificates.
`GLIBC-REQUIREMENTS.txt` records the actual glibc floor. This is a native build,
not the older Ubuntu 20.04 server compatibility bundle.

For packaging an existing matching libtorrent installation, set
`MINTTORRENT_NATIVE_PREFIX` to that installation prefix. For a different Qt,
set `MINTTORRENT_QT_PLUGINS` to its plugin directory.

## Ubuntu 20.04 / glibc 2.31 desktop kit

```
./scripts/build-desktop-ubuntu20-podman.sh
```

This reuses `localhost/minttorrent-builder:ubuntu20`, the same Ubuntu 20.04
Podman build kit as the server bundle, and its existing Go/libtorrent caches.
All compilation and packaging take place inside the container. The package is
`dist/MintTorrent-0.1.0-desktop-linux-x86_64-ubuntu20.04-glibc2.31.tar.gz`.
Extract it and run the `MintTorrent` ELF directly; no shell launcher is included.
The builder checks every packaged ELF against glibc 2.31, verifies checksums,
checks the authenticated desktop API and listener isolation, and renders the
main window, About and VPN/Netstack preferences with Qt's offscreen platform.

## Windows x86_64 cross-build

The build uses MinGW-w64, Ninja, Go with CGO, Boost headers, Windows OpenSSL and
zlib, and official Qt MinGW binaries. The initial build used Qt 6.8.3,
OpenSSL 3.0.16, zlib 1.3.1 and Boost 1.92.0 headers. Host moc/rcc/uic/lrelease
must match the Windows Qt version. Qt archives can be fetched with aqtinstall:

```
python3 -m venv build/desktop-tools
build/desktop-tools/bin/pip install aqtinstall
build/desktop-tools/bin/aqt install-qt windows desktop 6.8.3 win64_mingw -O build/windows-qt
build/desktop-tools/bin/aqt install-qt linux desktop 6.8.3 linux_gcc_64 -O build/windows-qt-host
```

Provide the following in `build/desktop-windows/native` before building:

- OpenSSL headers, import libraries (`libssl.dll.a`, `libcrypto.dll.a`) and DLLs;
- zlib headers, import library and DLL;
- Vulkan and vk_video headers in the native include directory (header-only);
- Boost headers and a CMake package exposing `Boost::headers` and `Boost::boost`.

OpenSSL can be cross-built from its official source archive with
`CC=gcc CXX=g++ ./Configure mingw64 --cross-compile-prefix=x86_64-w64-mingw32- shared no-tests --prefix=ABSOLUTE_NATIVE_PREFIX --libdir=lib`,
then `make -j4 && make install_sw`. zlib uses the toolchain file
`cmake/toolchains/windows-mingw64.cmake` with its normal CMake build/install.

```
./scripts/build-desktop.sh windows
./scripts/package-desktop-windows.py
```

Override Qt paths with `MINTTORRENT_QT_WINDOWS` and `MINTTORRENT_QT_HOST`.
Go is linked as a C archive into the libtorrent DLL, together with its C++
completion callbacks. The DLL exports the bridge API to qBittorrent; there is
only one Go runtime and one default stack. The packager checks recursive PE
imports and includes Qt plugins, OpenSSL, zlib and MinGW runtimes.

The package is `dist/MintTorrent-0.1.0-desktop-windows-x86_64.zip`.
Extract the complete ZIP and run `MintTorrent.exe`. Python search plugins are
disabled on Windows because the Linux seccomp socket sandbox cannot be used.
This preserves the rule that search child processes must not bypass the VPN.
Native Windows runtime, VPN transfer and packet-capture acceptance must be
performed on Windows; a successful cross-build does not establish them.

## Configuration

No private VPN profile is shipped in either desktop archive. Import your own
profile in Preferences/Options > AmneziaWG and click Save profile and connect.
The native controls call the same runtime functions as the existing WebUI API.
Netstack changes use the explicit Apply settings and reconnect VPN button.
Imported profiles, configuration and torrent state live in the MintTorrent user
profile. Stock qBittorrent's profile and the systemd server are separate.

## Local verification (2026-11-01)

The Linux package launched with bundled Qt libraries and rendered its main window
and both settings pages using the offscreen platform. Its authenticated API smoke
passed VPN-disabled state, proxy/interface lockdown, invalid MTU rejection and
clean shutdown. Archive and per-file checksums passed. Its native glibc floor is
2.44; this archive is not compatible with older distribution glibc versions.

The Windows x64 package passed recursive PE dependency resolution and the same
API smoke under Wine, including clean shutdown. Native Windows GUI interaction,
VPN transfers, recovery and packet capture remain untested. The MinGW build uses
a locally compiled UTF-8 Windows entry point so that a Qt SDK MSVCRT entry point
does not introduce incompatible CRT-global imports into a UCRT application.

The desktop packages use MintTorrent's M icon, mint-green accents and matching
light/dark palettes, a MintTorrent splash, About panel and Windows EXE metadata.
Linux starts directly from the `MintTorrent` ELF using its relative library path
and `qt.conf`; neither desktop archive includes shell launchers.

The Ubuntu 20.04 desktop package passed its glibc 2.31 ceiling check across
85 ELF files, checksum verification, API smoke and GUI rendering inside the
build kit. The same packaged ELF also passed the API smoke on the host outside
the container, without `/workspace` or `/opt/minttorrent-deps`. Its recorded
maximum required glibc symbol version is 2.30.
