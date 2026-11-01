# MintTorrent architecture

The current product base is the C++ qBittorrent 5.x nox server with its
original embedded WebUI/API. This is the user's explicit architecture choice
and supersedes the Rust-core preference in the draft specification.

```text
Browser --loopback TCP--> qBittorrent WebUI/API (qBittorrent C++ nox)
                               |
                         qBittorrent engine
                               |
                patched libtorrent 2.1 TCP/UDP/DNS facades
                               |
               AmneziaWG-Go + in-process gVisor Netstack
                               |
              configured encrypted AWG UDP endpoint only
                               |
                         host network
```

The gVisor stack is an in-process channel device. It creates no kernel TUN/TAP,
network namespace, host route, or host firewall rule. The AmneziaWG UDP
underlay is intentionally host-networked because it must reach the configured
VPN endpoint. Endpoint hostnames are not resolved with the host resolver.

AmneziaWG's peer handshake is monitored separately from data-path readiness.
The bridge immediately probes DNS and TCP to `example.com:443` through gVisor;
successful probes repeat every 30 seconds, while failures retry with
exponential delay up to five minutes. Status exposes the latest result.
AmneziaWG-Go continues its protocol-level handshake/retry behavior if the peer
is temporarily unavailable.

The patched libtorrent build redirects TCP sockets, acceptors, UDP sockets,
and DNS operations to an integer-handle C ABI backed by the Go stack. If no
stack is available, those operations fail instead of constructing native
external sockets. Qt HTTP requests use an unreachable local proxy; Python
search workers cannot create network sockets; SMTP and peer reverse-DNS are
disabled in this build because their upstream implementations bypass
libtorrent. WebUI listener sockets are the explicit local management-plane
exception.

Settings are stored in the qBittorrent profile. The MintTorrent settings
panels expose gVisor address-family/MTU/queue/TCP-buffer options and complete
AmneziaWG profile import/edit. The owner-only profile is loaded by qBittorrent
at startup and handed directly to the AWG bridge.

## Source map

- `vendor/qbittorrent`: upstream qBittorrent C++ app, WebUI/API, and MintTorrent
  controls/fail-closed restrictions.
- `vendor/libtorrent`: pinned libtorrent v2 source and custom network facades.
- `components/amneziawg-go`: AmneziaWG-Go with gVisor Netstack options.
- `components/awgnet`: c-shared Go bridge used by qBittorrent/libtorrent.
- `scripts/build-bundle.sh`: standalone Linux build and packaging.
- `install.sh`, `uninstall.sh`, `update.sh`: systemd installation, data-preserving
  removal, and checksum-verified update with rollback.

See [project-status.md](project-status.md) for the release gate and evidence.

## Platform independence

Platform independence is a product requirement, not a property of the current
Linux release. Keep torrent/session policy, VPN profile parsing, gVisor IP
processing, and WebUI/API behavior in the shared core. Isolate host UDP socket
creation, process replacement/signals, secure file permissions and paths,
service management, filesystem layout, and bundle creation behind explicit
platform adapters.

The first portability boundary has started in the Go CLI: hidden terminal input
uses `golang.org/x/term`, child-process launch uses the standard `os/exec` API,
and the standalone CLI cross-builds for Windows amd64 and FreeBSD amd64. This is
compile evidence for that executable only. The C++ qBittorrent/libtorrent
runtime, cgo bridge packaging, launcher, installers, systemd integration, and
platform-specific network underlay are not yet portable. A complete platform
port requires build and runtime tests for each target, not merely successful
cross-compilation of the CLI.
