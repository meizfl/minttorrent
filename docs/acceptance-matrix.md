# MintTorrent acceptance matrix

Audit date: 2026-11-01. This matrix maps every checkbox in section 20 of
[`ТЗ MintTorrent.md`](../ТЗ%20MintTorrent.md) to current evidence. `PASS` means
the stated behavior was exercised at the stated scope. `PARTIAL` means evidence
does not cover the full requirement. `OPEN` means acceptance has not passed.
`APPROVED DEVIATION` records a requirement the user explicitly replaced.

The user's later architecture direction is authoritative for implementation:
qBittorrent-nox C++ is the application base, libtorrent v2 is the torrent
engine, and AmneziaWG-Go/gVisor provide the userspace network path. Thus the
Rust checkbox below is documented as an approved deviation rather than silently
reported as met.

## Architecture

| Criterion | Status | Evidence / remaining work |
|---|---|---|
| Main application is written in Rust | **APPROVED DEVIATION** | User explicitly selected C++ qBittorrent-nox as the base and allowed Rust to be removed; the VPN bridge is Go. Current Linux build is C++/Go. |
| No SOCKS5 | **PASS** | The qBittorrent engine forces `proxy_type=none`; API attempts to enable SOCKS5 are normalized to `None`, including clearing stored credentials; the upstream proxy editor is hidden. Compatibility code remains in vendored upstream sources but cannot configure the MintTorrent session. Fresh bundle smoke checks the API attempt. |
| No HTTP CONNECT | **PASS** | HTTP proxy API attempts are likewise normalized to `None`; UI proxy controls are hidden and libtorrent is always configured without a proxy. Fresh bundle smoke submits an HTTP proxy attempt and checks the normalized preferences. |
| No system TUN/TAP is created | **PASS** | gVisor uses an in-process virtual NIC; AWG's TUN device is an in-memory packet interface. Runtime syscall audit found only the configured encrypted AWG UDP underlay externally. The qBittorrent listener configuration is compiled to wildcard selectors for MintTorrent's socket adapters and does not enumerate host interfaces. |
| System routes are not changed | **PASS** | Runtime uses the userspace stack and has no route setup; there is no TUN or namespace configuration in the service. Physical-interface packet capture remains a separate leak check. |
| Ordinary operation needs no host firewall changes | **PASS** | Bundle/service setup does not add firewall rules; the configured AWG endpoint uses ordinary outbound UDP. Provider-side inbound forwarding is separate. |

## VPN

| Criterion | Status | Evidence / remaining work |
|---|---|---|
| AmneziaWG is supported | **PASS** | Supplied AWG profile imported; live handshake and gVisor DNS/TCP health passed. |
| Userspace VPN transport works | **PASS** | AmneziaWG-Go packet transport connects to gVisor without a system TUN. |
| Automatic reconnection works | **PASS** | Dropping/restoring encrypted UDP forwarding at a route-bound relay recovered the handshake without re-importing the profile. |
| VPN loss is handled correctly | **PASS** | During relay outage, health went unhealthy and torrent bytes stopped; after restore the tunnel recovered and torrent progress resumed. A fresh test on the user-provided torrent after the listener isolation change held the downloaded counter at 7,614,716 bytes for the outage window, then recovered without profile re-import and resumed to 92,061,420 bytes. Physical link removal remains untested. |

## Network

| Criterion | Status | Evidence / remaining work |
|---|---|---|
| Internal TCP/IP stack works | **PASS** | gVisor in-process stack passed live DNS/TCP health and real torrent transfers. |
| TCP works | **PASS** | TCP-only peer transfers passed through AWG over IPv4 and IPv6. |
| UDP works | **PASS** | UDP tracker announces, uTP-only transfers, and DHT datagrams were observed through AWG. |
| DNS works | **PASS** | In-stack DNS health probe passed through the tunnel. |
| IPv4 works | **PASS** | Live TCP and uTP peer payload was observed from IPv4 peers. |
| IPv6 works | **PASS** | Live TCP and uTP peer payload was observed from IPv6 peers. |
| Torrent traffic never exits through host networking | **PARTIAL** | On the latest listener build, `strace` during a real user-provided torrent's UDP announce and μTP peer transfer observed one external destination (the configured AWG endpoint) and zero unexpected destinations. Host-interface capture during traffic and forced VPN loss is still required. |

## BitTorrent

| Criterion | Status | Evidence / remaining work |
|---|---|---|
| `.torrent` files work | **PASS** | Latest bundle live test through the supplied operator VPN profile announced the user-provided torrent, downloaded 5,374,802 bytes, verified 5 pieces, and observed BT/μTP peers plus one PeX peer. The active libtorrent session passed its startup assertion for the configured qBittorrent `-qB5300-` peer fingerprint. Earlier test with a temporary metainfo copy preserving the info-hash and adding OpenTrackr UDP downloaded 3,271,642 bytes and verified 2 pieces. |
| Magnet links work | **PASS** | Packaged CLI live magnet test announced and downloaded verified pieces through AWG. |
| Downloading works | **PASS** | Multiple live tests downloaded verified pieces; TCP-only/uTP-only and IPv4/IPv6 paths were exercised. |
| Uploading works | **PASS** | A live TCP-only run recorded 2,097,152 uploaded bytes, and the user confirmed the real-torrent test both downloaded and uploaded successfully. |
| UDP trackers work | **PASS** | The latest real transfer required and observed a successful `udp://tracker.opentrackr.org:1337/announce` row through AWG and verified 2 pieces; earlier TCP/uTP runs also observed successful UDP announces. |
| DHT works | **APPROVED DEVIATION** | DHT datagrams were exchanged, but trackerless tests over supplied Cloudflare WARP produced zero routing-table nodes, peers and pieces. The user explicitly accepted tracker-based operation as sufficient for this WARP deployment and noted DHT also performs poorly with stock qBittorrent through Cloudflare. DHT remains unclaimed as working. |
| PeX works | **PASS** | A PeX-required live run observed a PeX-discovered peer and downloaded verified pieces. |
| uTP works | **PASS** | Strict uTP-only live transfer downloaded verified pieces, including from IPv4 and IPv6 peers. |
| Incoming P2P works when VPN supports it | **OPEN** | Listener reports firewalled on the supplied WARP path. No provider-forwarded port or external inbound-peer test is available. |

## WebUI

| Criterion | Status | Evidence / remaining work |
|---|---|---|
| Original qBittorrent WebUI is used | **PASS** | qBittorrent 5.3.0 embeds its upstream WebUI; MintTorrent adds branded settings panels. |
| Standard authentication works | **PASS** | Authenticated API smoke and real browser login passed. |
| Torrent management works | **PASS** | API/UI smoke covers add, pause/resume, delete, trackers, peers, files/priorities, and restart restoration. Live peer-control test banned an active payload peer. |
| Categories work | **PASS** | Category CRUD and torrent category persistence were exercised. |
| RSS works | **PASS** | Feed fetch/parse/removal and RSS auto-downloader rule CRUD/export were exercised. |
| Statistics work | **PARTIAL** | Live sampler and APIs report rates, counters, peer rows, DHT and listener state. Chromium rendered the upstream Statistics dialog and its session/cache/performance/tracker sections on an authenticated idle instance; active-transfer updates in that dialog remain unverified. |
| WebUI remains available without VPN | **PASS** | Authenticated WebUI worked with VPN autostart disabled; VPN health and UI are independent. |

## Delivery and operations

| Criterion | Status | Evidence / remaining work |
|---|---|---|
| Standalone bundle exists | **PASS** | Native Linux x86_64 bundle rebuilt with the active-session PeerID check; a fresh CMake configure/build from an empty build directory passed, followed by the complete `minttorrent-check` aggregate (loopback WebUI/API smoke, update/archive checks, C++ adapters, CLI, and Go race tests). A second Ubuntu 20.04 bundle was built in Podman, all 27 packaged ELF files passed the `GLIBC_2.31` ceiling scan, its SHA-256 matched, and packaged smoke passed WebUI/API/CLI, metrics, torrent lifecycle, and IPv4/IPv6 loopback checks. Archive layout and SHA-256 verification passed. The native packaged build also downloaded the user-provided torrent over WARP and verified 5 pieces. |
| Installer script exists | **PARTIAL** | `install.sh` is included and validates bundle contents. The real script passed in an isolated Ubuntu 20.04 container: it created the system account, installed files with expected ownership/modes, preserved a modified config on reinstall, and routed enable/start through a fake systemctl. A clean host with a real systemd manager remains untested. |
| Uninstaller exists | **PARTIAL** | The real `uninstall.sh` passed in the same disposable container, removing the binary tree, command link, and unit while preserving the config and `/var/lib/minttorrent` user data. Real installed-service removal on a systemd host remains untested. |
| systemd unit exists | **PASS** | Unit is shipped and passed `systemd-analyze verify` in an isolated temporary root. |
| Automatic startup works | **OPEN** | Unit has `WantedBy=multi-user.target` and installer supports enabling it. Actual boot/systemd start remains unverified because the host system bus is unavailable. |
| Clean shutdown works | **PASS** | Temporary service exited cleanly on SIGINT; clean qBittorrent restart restored stopped torrent metadata/state. |
| Recovery after failure works | **PARTIAL** | VPN underlay outage recovery and isolated update rollback passed. Real systemd restart-on-failure and clean-host service recovery remain unverified. |
| Documentation exists | **PASS** | README and `docs/` cover build, configuration, VPN, installation, update, architecture, and current acceptance evidence. |
| CI/CD | **PARTIAL** | `.github/workflows/build.yml` builds the native Linux x86_64 bundle and an Ubuntu 20.04/glibc 2.31 bundle in Podman, runs the applicable checks, verifies checksums, and uploads both artifacts. Workflow syntax and the Ubuntu build script pass locally; hosted execution awaits pushing the workflow to the configured GitHub repository. |
| No RPM/DEB dependency | **PASS** | Distribution is a standalone archive, not an RPM/DEB package; compatible host glibc/ELF loader remains required. |

## External release gates

- Clean privileged systemd host for install/start/stop/update acceptance. The
  current environment cannot connect to the system bus.
- Host packet capture with `CAP_NET_RAW`/`CAP_NET_ADMIN` during torrent traffic
  and forced VPN loss. `scripts/test-network-packet-capture.sh` now runs the
  live torrent plus controlled AWG relay outage and rejects any public
  destination other than the configured endpoint. This workspace's kernel
  denies `AF_PACKET` even with elevated execution and has no tcpdump; run the
  packaged check on a host with packet-capture capability.
- A VPN provider-forwarded port and external peer for incoming-connection
  acceptance; the supplied WARP path currently reports the listener as
  firewalled.
- Stock qBittorrent plus system-VPN benchmark baseline for comparative
  performance claims.
- Broader browser-driven live statistics and settings workflows beyond the
  authenticated profile editor, native file chooser, saved default download
  path, and idle Statistics dialog checks already passed.

The current package is Linux-only. Windows Server, BSD, and desktop support are
future work explicitly deferred by the user; they are not claimed as delivered.
