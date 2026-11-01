# MintTorrent

A C++ desktop and server BitTorrent client based on qBittorrent 5.3.0 and
libtorrent 2.1.2. Torrent TCP, UDP and DNS use an in-process gVisor Netstack
carried by AmneziaWG-Go. Torrent traffic fails closed while that stack is
unavailable. The desktop and original WebUI expose AmneziaWG profile import and
gVisor settings, with MintTorrent branding and mint-green desktop accents.

The BitTorrent peer fingerprint intentionally remains `-qB5300-`; HTTP and
extension-handshake identification report MintTorrent and the upstream versions.
Upstream attribution and licenses are retained in the vendored sources.

## Run a desktop release

Extract the complete release archive. On Linux run `./MintTorrent`; on Windows
run `MintTorrent.exe`. All adjacent libraries and Qt plugins must remain beside
the executable. Desktop packages contain no shell launchers and no VPN keys.
Open Preferences/Options > AmneziaWG, import your own profile, then connect.

The Ubuntu 20.04 x86_64 package is the compatibility build (glibc ceiling 2.31).
The native Linux package requires glibc 2.44. Windows x64 was cross-built and
smoke-tested under Wine; native Windows VPN-transfer acceptance remains open.
See [desktop builds](docs/desktop-builds.md) and [release preparation](RELEASING.md).

## Build from this repository

All patched qBittorrent, libtorrent and AmneziaWG sources are included; no Git
submodule initialization or private configuration is required. Go dependencies
are resolved from the checked-in `go.mod` / `go.sum` files.

### Ubuntu 20.04 desktop and server build kit

Install Podman on a Linux x86_64 host, then run:

```sh
./scripts/build-desktop-ubuntu20-podman.sh
# Optional headless server package:
./scripts/build-ubuntu20-podman.sh
```

The kit builds Qt, Boost, OpenSSL, Go and CMake inside Ubuntu 20.04, checks the
packaged ELF ABI, runs smoke tests and writes versioned archives plus SHA-256
files. The first build compiles dependencies; subsequent runs reuse the image.
Desktop output is under `dist/`; server output is under `build/dist-ubuntu20/`.

### Windows desktop cross-build on Linux

Install GCC/MinGW-w64 with POSIX C++ threads, CMake, Ninja, Make, Perl, curl,
Python 3 with venv, p7zip, Go 1.25+, Boost headers and Vulkan headers. On Ubuntu:

```sh
sudo apt-get install build-essential cmake ninja-build mingw-w64 libboost-dev \
  libvulkan-dev python3-venv p7zip-full curl ca-certificates perl
./scripts/bootstrap-desktop-windows.sh
./scripts/build-desktop.sh windows
./scripts/package-desktop-windows.py
```

The bootstrap downloads Qt 6.8.3 through pinned aqtinstall and builds the pinned
OpenSSL/zlib sources, verifying their source archive hashes. It never requests
VPN credentials. Output is under `dist/`. See [build details](docs/desktop-builds.md).

### Native Linux builds

With Qt 6.6+ development modules (CorePrivate, Widgets, SVG, SQL, Xml, Network,
LinguistTools), Boost, OpenSSL 3, zlib, CMake, Go and a C++20 compiler installed:

```sh
./scripts/build-desktop.sh linux
./scripts/package-desktop-linux.sh
# Optional server build and checks:
cmake -S . -B build
cmake --build build --target minttorrent-check --parallel 2
```

## Server installation

Extract a server archive and run `./bin/minttorrent` in the foreground, or
`sudo ./install.sh` to install its systemd service. The WebUI defaults to loopback
port 4101; the first-run administrator password is printed to the console or
service journal. Import your own VPN profile after login. Existing installed
configuration and torrent data are preserved by the provided update tooling.

## Configuration and tests

The checked-in TOML defaults to `vpn.autostart = false`. Only a placeholder
profile example is supplied. Public server packaging also deliberately emits
an inert profile and excludes every operator `.conf`, even if present locally.
Import a real profile after installation. Never commit an active VPN profile,
private key, authentication token, local state or downloaded payload.

Offline checks and test commands are documented in [architecture](docs/architecture.md)
and [acceptance status](docs/project-status.md). Live tests require an explicitly
supplied VPN profile and authorized torrent and are not part of public CI.

The public CI builds Ubuntu 20.04 server/desktop and Windows cross-build assets,
checks packaging, and scans source and release contents for credentials. It
uploads workflow artifacts; it does not publish a GitHub Release automatically.
The first hosted run has not been observed from this local export.

## Known limits

The WARP path has not passed trackerless DHT-only discovery; tracker-based
operation is supported by the recorded tests. Incoming peers require provider
port forwarding. Host packet-capture leak acceptance and native Windows live
VPN transfers remain open. Windows Python search plugins are disabled because
the Linux socket sandbox is unavailable on that platform.

## License

MintTorrent is distributed under [GPL-3.0](LICENSE), with the upstream license
and copyright notices preserved. Third-party notices are in [licenses](licenses/THIRD-PARTY.md),
[component provenance](components/UPSTREAM.md) and the vendored source trees.
