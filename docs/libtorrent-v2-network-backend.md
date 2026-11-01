# libtorrent 2.1 userspace backend plan

## Pinned upstream

MintTorrent carries the official libtorrent `RC_2_1` revision recorded in
[`vendor/libtorrent/UPSTREAM.md`](../vendor/libtorrent/UPSTREAM.md). The pinned
source configures and compiles with the installed Boost/OpenSSL toolchain when
WebTorrent/WebRTC is disabled. WebRTC is outside the qBittorrent WebUI use case
and its upstream submodule is intentionally not vendored.

## Required replacement points

The networking implementation is not a single socket factory. These are the
distinct paths that have to be redirected to MintTorrent's AWG/gVisor stack:

| libtorrent path | Upstream location | Required backend surface |
|---|---|---|
| Outgoing peer TCP, HTTP(S) trackers, web seeds | `include/libtorrent/socket.hpp`, `include/libtorrent/aux_/socket_type.hpp`, `src/instantiate_connection.cpp` | TCP socket, endpoint/protocol types, async connect/read/write, cancel and close |
| Incoming peer TCP | `include/libtorrent/aux_/session_impl.hpp`, `src/session_impl.cpp` | TCP acceptor/listener and accepted stream creation |
| UDP trackers, DHT, LSD, NAT-PMP and uTP datagrams | `include/libtorrent/aux_/udp_socket.hpp`, `include/libtorrent/aux_/session_udp_sockets.hpp`, `src/udp_socket.cpp` | UDP bind, async readiness/read, send, local endpoint |
| uTP | `include/libtorrent/aux_/utp_socket_manager.hpp`, `src/utp_socket_manager.cpp` | Reuse the redirected session UDP path; must not open a second host UDP socket |
| DNS | resolver interface and `src/resolver.cpp` | A/AAAA lookups performed by the userspace stack only; no libc/system resolver fallback |
| optional network helpers | `src/lsd.cpp`, `src/upnp.cpp`, `src/natpmp.cpp`, `src/ip_notifier.cpp` | Disable or route through the backend; no host broadcast/multicast or external UDP |

The `tcp::socket` and `udp::socket` aliases are used as concrete Asio types in
many templates and variants. Replacing only peer construction would leave
trackers, DHT, uTP, or listeners on system sockets. The patch therefore needs
an Asio-compatible socket/acceptor facade backed by a narrow C ABI to the
Go-owned AWG/gVisor instance, plus a build-time mode that rejects accidental
construction of native external sockets.

## Data flow

The AWG Go device uses the official AmneziaWG implementation with its
`tun/netstack` device. The stack exposes TCP streams and UDP endpoints. C++
socket facades invoke that C ABI and marshal completion back onto libtorrent's
Boost.Asio `io_context`; the C ABI must not expose Go pointers or call a C++
handler from a Go goroutine. One owner controls stack/device lifetime, and
closing the network gate cancels every stream, listener, and datagram endpoint
before the torrent session can resume.

The VPN underlay remains one ordinary host UDP socket used by AWG to reach its
configured endpoint. No torrent-engine socket is allowed to use the host
network. The underlay endpoint must be numeric or resolved before startup
without sending DNS through the host resolver.

## Backend invariants

- No SOCKS5, HTTP CONNECT, local relay, TUN/TAP device, namespace, or host route
  is used for torrent traffic.
- Every torrent TCP and UDP operation belongs to a live userspace-stack handle.
- A backend-down state rejects new connects, sends and DNS requests and cancels
  active operations. There is no native-socket fallback.
- IPv6 is enabled only when the configured AWG routes IPv6; otherwise the
  stack rejects it.
- libtorrent listen endpoints must be the IP addresses configured in the
  active AWG profile. Do not configure wildcard listeners: libtorrent expands
  `0.0.0.0`/`::` against host interfaces, whose addresses do not exist in the
  isolated gVisor stack.
- DHT, uTP and UDP trackers stay enabled only after the UDP path is implemented
  and verified. LSD/UPnP/NAT-PMP cannot rely on host LAN interfaces.

## Current status

The pinned source and custom TCP/UDP socket, acceptor, asynchronous DNS, and
network-policy patches compile into libtorrent 2.1.2 through
`scripts/build-libtorrent.sh`. `ldd -r` confirms the application resolves the
libtorrent and AWG bridge libraries and the bridge's completion callbacks.
The standalone bundle includes libtorrent, the AWG bridge, and the non-glibc
shared-library dependencies resolved by the build. The runtime explicitly sets
libtorrent `proxy_type` to `none`; proxy routing is unavailable in this backend. The target still needs a
compatible glibc and ELF loader. Torrent management and the qBittorrent API are
implemented as a growing compatibility subset; real swarm seeding and leak
acceptance remain incomplete. Session-level DHT and peer counts are read from
libtorrent's `session_stats_alert` counters rather than hardcoded WebUI values.
MintTorrent also adds an ABI 2 `session_handle::get_peer_id()` accessor; engine
startup checks the generated ID from the live libtorrent session against the
configured qBittorrent 5.3.0 fingerprint before accepting the session.

The userspace listener is now configured from the active AWG profile's
`[Interface] Address` values. A live check found that wildcard listeners were
expanded by libtorrent into host interface IPs and all the gVisor-backed binds
failed with `Bad file descriptor`; this prevented DHT UDP from starting. The
address-scoped fix alone was insufficient: Asio queries an acceptor's local
endpoint after bind and before listen, so the custom acceptor must return its
configured endpoint before it has a Go listener handle. A separate FFI type
mismatch also treated gVisor `*gonet.UDPConn` handles as system `*net.UDPConn`.
The listener lifecycle and UDP type/API fixes are verified live: DHT grew to
140 nodes, exchanged hundreds of DHT messages, and a real 483 MB torrent
completed through the VPN with uTP peers, including an IPv6 peer. Incoming
TCP and systematic leak tests remain unverified. A synthetic 16 MiB v1 torrent
is seeded through the same live service and its 64 pieces have been verified
on disk. After adding `udp://tracker.opentrackr.org:1337/announce`, the live
tracker API returned status 2 and one leecher; libtorrent's payload-upload
counter reached 65,536 bytes. A complete leecher download and sustained upload
remain unverified.
