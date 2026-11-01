# MintTorrent acceptance status

Audit date: 2026-11-01. This status describes the current C++ qBittorrent
runtime in the working tree. Earlier Rust prototype results are not evidence
for the current runtime. The user explicitly selected qBittorrent-nox as the
project base; this overrides the Rust language choice in the original draft
specification.

For a criterion-by-criterion disposition of every checkbox in section 20 of
the specification, see [`acceptance-matrix.md`](acceptance-matrix.md).

## Requirements and evidence

| Requirement | Current evidence | Status |
|---|---|---|
| MintTorrent CLI | Packaged launcher supports `start/stop/restart/status`, `logs`, foreground `run`, qBittorrent argument forwarding, updater, authenticated VPN import/connect/disconnect/status, torrent add/list, and redacted config show. Go API tests and mock routing pass; bundle smoke covers status/disconnect/list/preferences; live torrent-file and magnet tests added through the packaged CLI announced and downloaded verified pieces through AWG. | Implemented for listed commands; full clean-host systemd lifecycle remains open. |
| Original qBittorrent WebUI/API | qBittorrent 5.3.0 C++ nox build embeds its own upstream WebUI resources; the standalone offline copy now comes from the same vendor tree. Smoke launch and authenticated settings/API checks passed on both `127.0.0.1:4101` and `[::1]:4101`. Torrent CRUD, tracker add/remove, reserved-IP peer blocklisting, speed-limit read/write, pause/resume, categories/tags, file priority, RSS refresh, and RSS auto-downloader rule CRUD/export are exercised. Live TCP/uTP runs returned connected-peer rows with observed payload. | Browser automation on temporary localhost instances opened both added settings tabs and selected a synthetic AWG file through Chromium's real file chooser, confirming its contents appeared in the profile editor without connecting the dummy endpoint. A separate authenticated editor test applied a harmless comment-edited profile, verified the saved file, and saw a received handshake plus healthy gVisor data path. Chromium also rendered the upstream Statistics dialog on an authenticated idle instance, and a Downloads setting changed in the UI was verified persisted in `qBittorrent.conf`. Active-peer banning passes in a strict TCP-only live run. Loopback smoke verifies invalid MTU/queue/TCP buffer values are rejected without changing the saved profile, an idempotent VPN disconnect succeeds, and malformed enable values are rejected. Active-transfer statistics rendering and broader settings coverage still need acceptance. |
| Inbound peer reachability status | gVisor settings explain that incoming peers depend on provider-side port forwarding; the application neither requests nor verifies a provider mapping, while outgoing tracker/peer traffic remains available. A stable forwarded port can be matched with `torrent.listen_port`. | UI smoke asserts the limitation text is served. Actual inbound reachability requires a VPN provider forwarding a port and an external peer test; not demonstrated with the supplied WARP profile. |
| MintTorrent branding and settings tabs | WebUI title, logo, About panel and app identity are branded as MintTorrent; separate gVisor Netstack and AmneziaWG panels remain. Internal API compatibility symbols and source/license attribution retain upstream names where needed. | qBittorrent's own session and the MintTorrent libtorrent engine both configure the qBittorrent 5.3.0 peer fingerprint (`-qB5300-`). The engine reads the generated peer ID from its active ABI 2 session and refuses startup if the prefix does not match. The latest live transfer created this session, announced, connected to BT/μTP peers, and downloaded verified pieces through WARP. Bundle smoke also verifies the qBittorrent session log and matching MintTorrent version in the HTTP User-Agent and extension handshake. |
| Userspace AmneziaWG + gVisor | Go c-shared bridge and customized `CreateNetTUNWithOptions` compile; C++ controller imports/starts/stops the profile. The current bundle imported the supplied operator VPN profile and reported a live peer handshake plus a successful DNS+TCP probe through gVisor, with nonzero tunnel counters. A route-bound UDP relay carried encrypted AWG transport; dropping and restoring forwarding caused health loss and autonomous handshake recovery without profile re-import. | Recovery and torrent continuation passed the controlled relay outage test. Physical interface loss and host packet-capture leak acceptance remain open. |
| Configurable stack buffers and MTU | Settings are validated and passed through the C ABI to gVisor's NIC MTU, packet queue and TCP buffer options. | A live test applied MTU 1280, queue depth 2048 and 2 MiB send/receive buffers through the API used by the Netstack settings button, verified the active status values and healthy VPN, then transferred TCP peer data. The test confirms application and continued operation; performance comparison against defaults remains open. |
| Libtorrent TCP/UDP/DNS isolation | Pinned libtorrent 2.1.2 has custom TCP, acceptor, UDP and DNS socket adapters and is compiled with `TORRENT_USE_MINTTORRENT_NETSTACK`; no native fallback is intended. qBittorrent no longer exposes host interfaces or host IP addresses in its bind selectors; the MintTorrent compile-time branch returns only wildcard selectors and compiles out Qt host-interface enumeration in the listener path. Stale interface preferences are cleared. Proxy settings are forced to `None` for the session. | C++ adapter check verifies DNS/TCP failure and listener/UDP bind rejection with no active gVisor stack; active-stack fake tests cover retries and UDP send/receive. The full `minttorrent-check` rejects host-interface enumeration and smoke-tests loopback/API behavior. The packet-capture parser has automated IPv4/IPv6 and leak-rejection fixtures. The packaged `tcpdump` harness can capture a real torrent transfer and controlled VPN outage; this kernel denies `AF_PACKET`, so host packet-capture acceptance remains open. |
| Native-network bypass prevention | Qt HTTP stays on a fail-closed proxy by default; RSS and its icons use the direct gVisor HTTP adapter. Python search child sockets are denied and proxy environment variables are stripped; SOCKS/HTTP proxy controls and API activation are disabled. SMTP and PTR lookups are disabled. AmneziaWG's numeric configured endpoint still uses its required encrypted host UDP underlay. | Latest-build `strace` during a real user-provided torrent's UDP announce and μTP peer transfer observed one external destination (the configured AWG endpoint) and zero unexpected destinations. Host-interface packet capture during traffic and forced VPN loss remains. |
| Fail-closed and recovery | Torrent socket facade rejects operations without an active gVisor stack; AWG transport uses AmneziaWG-Go. The in-stack DNS+TCP monitor reports readiness and retries probes with bounded exponential delay. A fresh test on the user-provided torrent dropped encrypted UDP forwarding after transfer began, observed unhealthy VPN status and a stable downloaded counter at 7,614,716 bytes through the outage window, restored forwarding, recovered without profile re-import, and resumed to 92,061,420 bytes. | Controlled AWG transport outage and torrent resume passed on the latest listener build. Physical link failure, exhaustive retry/backoff characterization, and packet-capture leak acceptance remain open. |
| BitTorrent lifecycle | The C++ engine selects a per-run BitTorrent port in `10000–65535`, keeps WebUI configuration-controlled with a default of `4101`, and disables proxy/UPnP/NAT-PMP/LSD fallback paths. | Separate live tests passed TCP-only and uTP-only peer modes through AWG, each with verified pieces and successful UDP tracker announces. TCP-only peers transferred data over both IPv4 and IPv6. PeX discovery was independently observed in the qBittorrent PeX pseudo-tracker row while downloading a verified piece. After the latest listener isolation change, the user-provided torrent downloaded 7,380,122 bytes and verified 5 pieces over TCP/μTP; the subsequent live run with the ABI 2 PeerID assertion passed through WARP, downloaded 5,374,802 bytes, verified 5 pieces, and observed BT/μTP peers plus one PeX peer; a second run with a temporary OpenTrackr tracker (same info-hash) required and observed one successful UDP announce, downloading 3,271,642 bytes and verifying 2 pieces over μTP/IPv4. The relay outage run held progress at 7,614,716 bytes during the outage and resumed to 92,061,420 bytes after tunnel recovery. A 120-second live sample through the supplied operator VPN profile downloaded 482,728,005 bytes (4.02 MB/s average), averaged 20.45% of one CPU core, 121.96 MiB RSS, and 7.61 connected peers; uploaded bytes remained zero. A 30-second TCP-only run downloaded 458,300,836 bytes, uploaded 2,097,152 bytes, averaged 15.09 MB/s, 101.54% of one CPU core, 138.83 MiB RSS, and 8.26 peers. Positive TCP RTT estimates appeared in 21/31 samples; their sample-averaged mean was 94.20 ms. A custom-settings TCP run applied MTU 1280, queue 2048 and 2 MiB TCP buffers, then downloaded another 343,039,890 bytes in 15 seconds over AWG. A later tracker-based session showed 26–32 DHT nodes, but trackerless DHT-only operation over the supplied operator VPN profile still produced zero nodes, peers, and pieces after 180 seconds. That run exchanged 4,082 bytes out, 4,697 bytes in, 38/18 DHT messages, with zero libtorrent-dropped messages. TCP RTT is the connect estimate, not a VPN-only probe or qBittorrent comparison. The user accepts tracker-based operation for the Cloudflare WARP path; DHT-only discovery remains an approved deviation. A stopped synthetic torrent survives a clean qBittorrent shutdown/restart with its metadata intact. A stock-qBittorrent/system-VPN baseline, incoming-port forwarding, and host packet-capture leak acceptance remain open. |
| Standalone bundle | Archive contains qBittorrent nox, native libraries, static CLI, Qt SQL/TLS plugins, matching offline WebUI, licenses, smoke/syscall-audit/update-validation/rollback/preservation scripts, systemd unit, VPN import instructions and SHA-256 manifest. Root CMake now orchestrates bridge, libtorrent, qBittorrent, CLI and packaging in dependency order. | Latest `minttorrent-check` passed: loopback WebUI/API smoke, update validation/rollback/preservation, host-interface isolation, C++ socket adapters, Go CLI tests, and AWG race tests. The Ubuntu 20.04/GLIBC 2.31 bundle also built in Podman: its 27 ELF files passed the ABI ceiling check, checksum verification passed, and the packaged smoke covered authenticated WebUI/API/CLI, metrics, torrent lifecycle, and IPv4/IPv6 loopback. The native packaged build downloaded the user-provided torrent through WARP and verified 5 pieces. Clean-host install and real systemd startup/update remain. |
| CI/CD | GitHub Actions workflow builds the native Linux x86_64 bundle and a separate Ubuntu 20.04/GLIBC 2.31 bundle in Podman, runs their applicable checks, verifies checksums, and uploads both artifacts for pushes, pull requests, version tags, and manual runs. | Workflow syntax and the Ubuntu build script pass locally. The first hosted run cannot be observed until this source is pushed to a GitHub repository; no remote repository is configured in this workspace. |
| Runtime configuration | `config/config.toml` is parsed at launch; relative VPN paths resolve against the config directory, configured WebUI and BitTorrent ports are passed to qBittorrent, and the storage path is applied to the session. Installer creates `/etc/minttorrent/config.toml` without overwriting it on upgrades. | Implemented and smoke-checked at ports 4101 and 4102. |
| Cross-platform foundation | CLI hidden-password input uses the portable Go `x/term` API instead of Linux-specific ioctl calls; the standalone CLI cross-compiles for Windows amd64 and FreeBSD amd64. | Partial: compile-only evidence for the CLI. The C++ runtime, libtorrent adapters, launcher, service/install/update system, and bundle are still Linux-specific; no Windows/BSD runtime is claimed. |
| Least privilege and preservation | Installer creates a dedicated account; uninstaller retains `/var/lib/minttorrent`; service uses systemd hardening. | Script source verified; root/systemd lifecycle has not been run in this environment. |

## Release gate still open

The build and WebUI loopback smoke checks are not sufficient for a release.
The following acceptance evidence is still required on the C++ bundle:

1. Import the supplied AmneziaWG profile, pass DNS and TCP health probes, and
   verify the UI remains usable while the VPN is unavailable. The positive
   profile probe, controlled loopback endpoint failure/recovery through the
   WebUI import API, explicit WebUI disconnect/reconnect, and a dropped/restored
   encrypted UDP relay test with autonomous recovery and torrent continuation
   passed. Physical interface/link loss remains untested.
2. Torrent-file and magnet downloads both announced and delivered verified
   pieces through AWG in temporary profiles. The user confirmed that the real
   torrent test both downloaded and uploaded successfully; a live TCP-only
   capture also recorded 2,097,152 uploaded bytes. A stopped synthetic torrent
   and its category/tag metadata survive a clean application shutdown/restart.
3. Exercise TCP peers, uTP, DHT, PeX, IPv4 and IPv6 separately. TCP-only and
   uTP-only runs now each announced through UDP trackers and downloaded verified
   pieces. Strict TCP-only and uTP-only runs each confirmed payload from both
   IPv4 and IPv6 peers. A separate PeX-required run observed a PeX-discovered
   peer and verified pieces.
   A trackerless,
   webseed-free DHT run exchanged DHT datagrams (4,933 bytes out, 9,894 in in
   one run; 3,666 out, 6,241 in, 34 messages out, 16 in and 0 dropped in a
   second; and 4,082 out, 4,697 in, 38 messages out, 18 in and 0 dropped in a
   trackerless retry over the supplied operator VPN profile) but produced zero
   routing-table nodes, peers and pieces. A tracker-based transfer on the same
   profile showed 26–32 DHT nodes, which did not translate into trackerless
   peer discovery. The user reports stock qBittorrent also has poor DHT
   connectivity through Cloudflare and accepts tracker-based operation as
   sufficient for this project. This is an approved deployment deviation; DHT
   remains a known network limitation with no success claim.
4. Capture host interfaces during torrent traffic and during forced VPN loss;
   prove that only the configured encrypted AWG UDP underlay reaches the host
   network and that no tracker, DNS, peer or web-seed request leaks directly.
   A process-level `strace` audit during a live UDP-tracker download saw one
   external destination (the configured AWG endpoint) and zero unexpected
   destinations; packet capture remains required to close this gate.
5. Verify autonomous behavior during an underlay outage: fail-closed torrent
   behavior, backoff, endpoint reconnect, and torrent continuation. A
   route-bound UDP relay test now passed: encrypted UDP forwarding was dropped,
   VPN health became unhealthy, the torrent made no byte progress for the
   outage window, and restoring forwarding recovered the AWG handshake and
   resumed the torrent without profile re-import. Physical interface/link loss
   and exhaustive backoff characterization remain open.
6. Exercise the major upstream WebUI/API workflows against this C++ build,
   including add, pause/resume, file priorities, categories/tags, trackers,
   peers, RSS rules/autodownloader, speeds, deletion, and settings. RSS
   feed fetch/parse/removal and rule create/list/clone/rename/export/delete
   pass. The stopped-torrent smoke now exercises tracker add/list/remove,
   reserved-address peer blocking, and upload/download speed-limit read/write
   without contacting any tracker or peer. Live TCP/uTP runs returned connected
   peer rows with payload counters. A strict TCP-only live check banned a
   payload-carrying peer through `transfer/banPeers`, verified the address in
   the temporary IP filter, and confirmed the peer closed/disappeared from the
   original API. The settings API now applies a non-default MTU, queue depth,
   and TCP buffer sizes, keeps the VPN healthy, and passes live TCP torrent data.
   A browser session authenticated to a temporary localhost build, applied an
   edited profile through the visible UI button, and then showed a received
   handshake and healthy gVisor data path. A separate isolated browser check
   selected a synthetic profile through Chromium's native file chooser and
   verified it populated the profile editor without connecting its dummy
   endpoint. Chromium rendered the Statistics dialog on an idle session, and a
   changed Downloads path persisted to `qBittorrent.conf`; active-transfer
   Statistics updates and broader settings workflows remain open. The loopback
   smoke also verifies rejected MTU, packet queue, and TCP
   buffer boundaries do not overwrite the saved profile; VPN disable through
   its settings API is idempotent, and malformed enable values are rejected.
7. Install the extracted bundle on a clean systemd host, verify service
   lifecycle and logs, then test rollback behavior for an update whose new
   service fails to start. Rollback logic is covered with a fake systemd
   controller in a user namespace; the installed host service still needs
   acceptance. Checksum rejection and unsafe archive validation are covered in
   isolation. The host must have a compatible glibc/ELF loader.
8. Run sustained throughput, CPU, memory, and connection-count comparisons
   required by the specification. One 120-second MintTorrent run has been
   recorded in `build/minttorrent-live-benchmark.csv`: 482,728,005 bytes
   downloaded (4.02 MB/s average), 20.45% average CPU use of one core,
   121.96 MiB average RSS, 7.61 average connected peers, and zero uploaded
   bytes. This single run does not satisfy the comparison requirement. The
   stock-qBittorrent/system-VPN baseline remains missing. The sampler now also
   records session-level rates/counters, DHT nodes and counters, and listener
   connection status. A 30-second TCP-only
   run recorded 458,300,836 bytes downloaded, 2,097,152 bytes uploaded, and
   positive peer RTT estimates in 21 of 31 samples (mean of per-sample peer
   averages: 94.20 ms). The peer API and sampler collect libtorrent's TCP
   connection RTT estimate; it is not available for all peer transports and
   does not isolate VPN latency. The live harness can save further samples via
   `MINTTORRENT_TEST_BENCHMARK_SECONDS` and
   `MINTTORRENT_TEST_METRICS_CSV`; the sampler is included in the bundle.

9. Run the GitHub Actions workflow on the configured remote. The Ubuntu 20.04
   job has now built and smoke-tested locally in Podman; hosted execution and
   artifact upload cannot be observed until this workspace is pushed to a
   GitHub repository.

## Host-side verification constraints

The current build environment runs as uid 1000 with no `CAP_NET_RAW` or
`CAP_NET_ADMIN`; neither `tcpdump` nor `tshark` is installed. The systemd
runtime directory exists, but `systemctl` cannot connect to the system bus
(`Operation not permitted`). Therefore physical-interface packet capture and
real privileged installation/service lifecycle acceptance require a separate
Linux host with packet-capture and systemd access. The process-level `strace`
audit and isolated updater tests do not replace those checks.

## Verified in the current audit

- `scripts/build-ubuntu20-podman.sh` produced the standalone
  `ubuntu20.04-glibc2.31` bundle using glibc 2.31. The ABI scanner checked all
  27 packaged ELF files and found no newer GLIBC symbol requirement; archive
  checksum verification and the complete packaged smoke passed, including
  authenticated WebUI/API/CLI, metrics sampling, torrent lifecycle, and
  IPv4/IPv6 loopback. The same disposable container also exercised the actual
  installer and uninstaller scripts with a fake systemctl, checking account,
  file ownership/modes, enable/start routing, config preservation, and user
  data retention. The first hosted GitHub Actions execution is still pending a
  push to the remote repository.
- `scripts/build-bundle.sh` completed after the Rust prototype was removed.
- The root CMake workflow was exercised from a fresh build directory using
  `cmake .. && make`; component outputs and the versioned archive were kept
  under `build/artifacts/` and `build/dist/`. Its `minttorrent-smoke` target
  passed authenticated WebUI/API and torrent add/delete checks on both
  loopback families. CMake builds are Linux-only and explicitly say so at
  configure time until the runtime platform adapters are implemented.
- The aggregate `make minttorrent-check` target passed: loopback-only bundle
  smoke, mocked launcher/CLI routing, and the C++ socket-adapter retry/bind/
  send/async-receive/close check against the CMake build outputs, Go CLI API
  tests, race-enabled AWG/gVisor bridge tests, update checksum/archive
  validation, and an isolated fake-systemd rollback test.
  `systemd-analyze verify` also passed against the shipped unit in a temporary
  fake root containing the expected launcher path and service directories. The
  host systemd manager still cannot be reached here, so this checks unit
  syntax/references only, not installation or service startup.
- `GOCACHE=/tmp/minttorrent-awg-cpp-race-gocache go test -race -count=1 -tags awgnet_test ./...` passed for the AWG bridge, including health-state transition checks.
- The packaged `scripts/smoke-bundle.sh` passed against the release bundle:
  qBittorrent API authentication, version, VPN status, private preferences,
  MintTorrent tabs, CLI commands, IPv4/IPv6 loopback, tracker metadata
  add/list/remove, reserved-address peer blocklisting, upload/download speed
  limit read/write, RSS rule CRUD, and synthetic torrent file/priority/
  category/tag/pause/resume/delete workflows. The torrent stayed stopped during
  tracker and peer-control checks; no torrent tracker or peer traffic was sent.
- The latest smoke also verifies the HTTP User-Agent and BitTorrent extension
  handshake contain the same MintTorrent/qBittorrent/libtorrent version string,
  the qBittorrent peer ID fingerprint is `-qB5300-`, and a stopped torrent
  retains its hash, name, category, tags and stopped state after clean restart.
  After proxy lockdown, it also submits SOCKS5 and HTTP proxy settings through
  the qBittorrent preferences API and verifies the server keeps proxy type
  `None`, clears credentials, disables every proxy-purpose flag, and serves only
  the MintTorrent transport notice in the WebUI.
- After correcting the shipped README to document that wire identity, the
  standalone bundle was rebuilt. Its fresh loopback smoke passed authenticated
  WebUI/API, VPN/Netstack validation, settings, torrent/tracker CRUD, peer
  blocklist, speed limits, metrics, restart restoration, and IPv4/IPv6 WebUI
  checks; it sent no torrent tracker or peer traffic. Archive checksum/layout
  verification passed on the rebuilt tarball.
- The live torrent integration harness queried the original authenticated
  `sync/torrentPeers` API. Strict TCP/uTP runs observed actual peers, payload
  counters, both IP families, and verified pieces. The stopped-torrent smoke
  verifies peer blocklist control with a reserved documentation address. A
  strict live TCP-only run selected an active peer with payload, called
  `transfer/banPeers`, confirmed its IP in the temporary banned-IP preference,
  and observed that the original peers API no longer listed that peer.
- The live metric sampler passed both packaged smoke and real transfer runs.
- A clean CMake build directory configured and compiled the complete Linux
  bundle from vendored sources. `cmake --build ... --target minttorrent-check`
  passed all aggregate checks, including the authenticated IPv4/IPv6 loopback
  smoke, C++ userspace socket adapters and interface-isolation check, Go race
  checks, update validation/rollback/preservation, and packet-capture parser
  fixtures. The first sandboxed smoke attempt could not bind loopback (`EPERM`);
  rerunning the same aggregate with local-bind permission passed. The separate
  Ubuntu 20.04 bundle still passes its GLIBC 2.31 scan and packaged smoke.
  On a 120-second uTP run it collected 121 rows and observed 482,728,005
  downloaded bytes; on a 30-second TCP-only run it collected 31 rows, saw
  21 positive peer RTT estimates, 458,300,836 downloaded bytes, and
  2,097,152 uploaded bytes. CSV output remains in `build/` for review.
- The current metrics sampler also records qBittorrent session totals/rates,
  DHT byte/message counters and node count, and listener connection status;
  the packaged loopback smoke verifies those columns without network activity.
  A 20-second TCP-only live sample showed changing global transfer totals and
  rates, 26–32 DHT nodes, 0 dropped DHT messages, and `firewalled` listener
  status while the torrent transferred through the VPN.
- The source-level `scripts/test-netstack-socket-retry.sh` passed against the rebuilt C++ adapters using a fake AWG C ABI: default-constructed TCP sockets connect without an explicit `open()`, explicitly closed sockets retry another endpoint, explicit local binds survive retries, and the UDP facade binds, reports its actual local endpoint, sends a datagram, asynchronously receives a payload with its source endpoint, and closes cleanly. It creates no network sockets and sends no packets; real UDP tracker/DHT/uTP traffic still needs separate acceptance.
- The C++ bundle was run under `strace -f -e trace=network` with the supplied AWG profile imported through `minttorrent vpn import`. The CLI reported healthy DNS+TCP data path and a live handshake; the process used one non-loopback destination, matching the profile's AWG endpoint, and no other external destination. `minttorrent vpn disconnect` then stopped the active stack. No torrent was added. The packaged `scripts/audit-network-syscalls.sh` makes this check repeatable.
- The release archive SHA-256 manifest and safe archive layout pass
  `./update.sh --verify-only`.
- `scripts/test-update-validation.sh` passes: a valid synthetic bundle is
  accepted while a stale checksum, traversal path, and escaping symlink are
  rejected.
- `scripts/test-update-rollback.sh` passes inside an isolated user namespace:
  when the replacement service never becomes active, the prior binary tree and
  systemd unit are restored. The test uses a fake `systemctl` and does not
  touch the machine's installed service or `/etc` unit.
- `systemd-analyze verify --root=... /etc/systemd/system/minttorrent.service`
  passed against a temporary root containing the unit and a stub launcher;
  no service was installed or started on the host.
- `scripts/test-cli.sh` verifies systemd lifecycle/log command routing and
  foreground qBittorrent argument forwarding without invoking real system
  services or starting a torrent.
- Go API tests pass for both qBittorrent session-cookie formats, VPN profile
  form submission, torrent file/magnet addition, and sensitive config redaction.
  Their fake HTTP server uses an in-memory RoundTripper, so these unit checks do
  not depend on host loopback socket permissions. The full
  `cmake --build build --target minttorrent-check -j2` aggregate passed after
  the proxy lockdown, including API attempts for SOCKS5 and HTTP being
  normalized to `None`; the bundle was rebuilt and its archive checksum/layout
  verified.
- The packaged CLI authenticated successfully with qBittorrent 5.3.0 and
  returned VPN status, disconnected the already-disabled VPN, listed the empty
  torrent set, and displayed preferences through the original API.
- `components/cli` builds as a standalone Go binary and is bundled beside
  qBittorrent. It reads WebUI passwords from hidden terminal input using
  cross-platform `x/term`, or from `MINTTORRENT_WEBUI_PASSWORD`; cleartext HTTP
  is restricted to loopback. Windows amd64 and FreeBSD amd64 cross-builds pass
  for the CLI only.
- The bundled executable launches and reports `qBittorrent v5.3.0`.
- Bundled qBittorrent ELF dependencies resolve with the bundle library path.
- The bundled WebUI returned HTTP 200 on IPv4 and IPv6 loopback at port 4101.
- qBittorrent login created a valid SID; authenticated version, MintTorrent VPN-status and private preferences requests returned HTTP 200. The two custom settings tabs were present in the authenticated original preferences view.
- The gVisor settings page now displays the provider-side port-forwarding
  limitation and explains how to match a stable forwarded port. The packaged
  smoke test checks this text is present in the authenticated preferences
  document. No forwarding request or inbound reachability is claimed.
- The AmneziaWG settings view reports the active profile path. `config/config.toml`
  is an active runtime input; its VPN profile, WebUI/P2P ports, and download path
  are consumed by the launcher and C++ qBittorrent process. The installer keeps
  `/etc/minttorrent/config.toml` across upgrades.
- The standard qBittorrent network-interface and bind-address APIs now return
  no host adapters; WebUI presents only the gVisor logical stack. The packaged
  smoke now submits stale `eth0`/host-IP values through the original settings
  API and confirms the response clears both. Old saved physical-interface
  values are reset to the userspace wildcard binding.
- In a temporary qBittorrent profile, the C++ build imported `/path/to/vpn-profile.conf`, negotiated a peer handshake, and passed its DNS+TCP data-path probe through gVisor (`data_path_healthy=true`, nonzero AWG counters). The profile file was stored with mode 0600. No torrents were added and no swarm was started.
- A `strace -f -e trace=network` run of that live C++ VPN probe observed exactly one non-loopback destination, the numeric AWG endpoint in the supplied profile; no other external destination appeared. This proves the probe's process-level syscall path only; it does not replace packet capture while torrent protocols are active.
- The test qBittorrent process stopped cleanly after the VPN probe; no `qbittorrent-nox` process remained.
- After the interface and profile-status changes, `scripts/build-bundle.sh`
  completed, the bundle smoke passed on both loopback families, and a fresh
  live AWG audit using `config/vpn/default.conf` passed DNS+TCP health and
  observed only the configured AWG endpoint. No torrent was added.
- The first live announce attempt exposed host addresses in libtorrent's
  interface expansion and failed with `no route to host` inside gVisor. The C++
  engine now enumerates the active gVisor interface addresses only, does not read
  host routes, and refreshes listeners after VPN changes. The zero-port wildcard
  TCP path also no longer binds `::` explicitly inside gVisor.
- The rebuilt bundle passed live tests with the official Debian 13.7 netinst
  torrent in temporary profiles over the supplied AWG configuration. Final CLI
  torrent-file and magnet runs both disconnected/reconnected VPN through WebUI,
  announced, and downloaded verified pieces through reopened sockets: file mode
  received 4,257,608 bytes with 9 verified pieces; magnet mode received
  2,620,194 bytes with 10 verified pieces. Neither test used the user's profile
  or download directory. Comparative sustained-throughput results remain open.
- The updated live integration script imported a copy of the supplied AWG
  profile whose sole endpoint was `127.0.0.1:9`. VPN status reported the data
  path unhealthy; re-importing the original profile restored handshake and
  DNS+TCP health. The subsequent official Debian torrent-file run announced
  and downloaded 2,515,902 bytes with 19 verified pieces via AWG. The endpoint
  test used a temporary profile and made no firewall changes; it verifies
  recovery after profile re-import, not automatic recovery from an underlay
  outage.
- With `MINTTORRENT_TEST_REQUIRE_UDP_TRACKER=1`, the live script required a
  successful UDP tracker row from the official Debian torrent. On the latest
  release bundle, after the controlled VPN failure/recovery and WebUI
  disconnect/reconnect checks, the run downloaded 6,377,629 bytes with 26
  verified pieces and reported five successful tracker rows, including two UDP
  tracker rows. This confirms tracker-based torrent traffic on the current
  build; it does not separately prove DHT or uTP.
- A route-bound UDP relay recovery run passed on the supplied AWG profile with
  the official Debian torrent: it first downloaded 5,682,779 bytes; during the
  dropped-forwarding outage the torrent counter stayed at 11,541,414 bytes for
  the full 8-second check. Restoring relay forwarding recovered AWG health and
  the handshake without profile re-import, and torrent progress resumed to
  794,487,358 bytes. The harness also required successful UDP tracker rows and
  verified torrent pieces. This is controlled encrypted-transport interruption,
  not physical interface removal or packet-capture evidence.
- The live torrent harness was run with
  `MINTTORRENT_TEST_AUDIT_NETWORK=1` and a successful UDP tracker required. It
  announced and downloaded 1,132,992 bytes, verified 7 pieces, and observed one
  non-loopback system-socket destination matching the configured AWG endpoint;
  unexpected external destinations: zero. This traces the process syscalls,
  while host-interface packet capture remains a separate acceptance check.
- Repeated the same audit from the freshly packaged archive after the CLI
  terminal portability change: 1,093,107 bytes downloaded, 11 verified pieces,
  two successful UDP tracker rows, and only the configured AWG endpoint among
  external system-socket destinations.
- On the current bundled test harness, a combined TCP-only/IPv4/IPv6/syscall
  audit downloaded 13,762,824 bytes and verified 45 pieces through six
  successful tracker rows, including two UDP rows. Peer data came from TCP
  connections over both address families; system syscalls still showed only
  the configured AWG endpoint and zero unexpected destinations.
- Strict protocol runs used a temporary profile and set qBittorrent's
  `bittorrent_protocol` preference before adding the test torrent. TCP-only
  mode transferred 677,235 bytes and verified 15 pieces with a TCP peer; uTP-
  only mode transferred 1,805,019 bytes and verified 4 pieces with `μTP` peers.
  Both had two successful UDP tracker rows. A stricter TCP-only run required
  payload from both IPv4 and IPv6 peer addresses and passed with 9,212,399
  downloaded bytes, 64 verified pieces, and PeX count 1. A uTP-only run also
  required and observed payload from both address families, downloading
  5,295,058 bytes with 23 verified pieces. A separate PeX-required run passed
  with a PeX row reporting one peer, 23,479,374 downloaded bytes, and 79
  verified pieces. These tests validate observed swarm protocols/families; they
  do not establish inbound reachability through the WARP provider.
- RSS feed download and parsing were added to the userspace gVisor HTTP path;
  the request fails closed if there is no active stack and does not fall back
  to Qt's native socket path. The authenticated live test added the RSS 2.0
  sample feed, refreshed it, verified parsed articles, and removed it before
  continuing the Debian UDP-tracker torrent test. The run downloaded
  1,519,893 bytes, verified 8 pieces, and reported five successful tracker
  rows including two UDP rows.
- The syscall audit was repeated with RSS refresh active under `strace`: one
  non-loopback destination matched the configured numeric AWG endpoint, zero
  unexpected external destinations were observed, and RSS articles parsed.
  This establishes the RSS+VPN process socket path only; torrent traffic still
  needs packet capture.
- The loopback smoke exercises RSS auto-downloader rule create, list, clone,
  rename, export and delete through the original API with VPN disabled and no
  feed attached; all operations passed without network traffic.
- A DHT-only run stripped trackers and web seeds from a temporary copy of the
  official Debian torrent while retaining the exact `info` bytes. The API
  showed DHT enabled and the default bootstrap hosts; two `DHT bootstrap
  completed` alerts were logged. After 180 seconds the session still had zero
  DHT nodes, peers, downloaded bytes, and verified pieces, despite libtorrent
  recording 4,933 outbound and 9,894 inbound DHT bytes. Thus DHT datagrams
  reached libtorrent, but the routing table did not accept a live node; the
  exact response/rejection condition is still under investigation. API
  counters expose incoming/outgoing messages and libtorrent-dropped messages.
  No DHT success is claimed.
- A later trackerless run used the supplied operator VPN profile and a temporary
  copy of the user's torrent with its exact info bytes preserved. After
  180 seconds it still had zero DHT nodes, peers, downloaded bytes, or verified
  pieces, despite 4,082 outbound and 4,697 inbound DHT bytes, 38 outbound and
  18 inbound messages, and zero dropped messages. Bootstrap completion alerts
  occurred, but DHT transactions did not populate a routing table. In a separate
  tracker-based TCP sample on the same profile, DHT status showed 26–32 nodes;
  this is not evidence of trackerless peer discovery.
- The user reports a live real-torrent test completed successfully and the
  client both downloaded and uploaded after adding an external tracker. This is
  user-reported evidence; no independent upload byte counter or second-client
  capture was collected in this audit.
- After MintTorrent branding and API version changes, the rebuilt bundle passed
  archive checksum/layout verification and the authenticated smoke test on
  IPv4/IPv6 loopback at port 4101. DHT error/bootstrap alerts are now exposed in
  the app log. The standard transfer-info API reports DHT byte/message counters,
  rates, and libtorrent-level dropped messages for live diagnosis. The
  extension-handshake version and HTTP User-Agent identify MintTorrent and
  include qBittorrent/libtorrent versions; the binary peer ID deliberately uses
  qBittorrent's `-qB5300-` fingerprint at the user's request.
- The user considers tracker-based download/upload acceptable after noting that
  stock qBittorrent also has poor DHT connectivity through Cloudflare WARP.
  This is a user-approved network limitation; DHT itself has not passed.
- qBittorrent C++ source rebuild succeeds with fail-closed SMTP and reverse-DNS
  behavior enabled by `TORRENT_USE_MINTTORRENT_NETSTACK`.
- No Rust source, Cargo manifest, or Rust executable remains in the runtime
  package or source tree.
- The current bundle remains Linux-specific. The product goal is full platform
  independence; isolate host UDP, tunnel lifecycle, service management,
  storage, and packaging behind platform adapters before adding Windows Server,
  BSD, or desktop targets. No non-Linux target is claimed as implemented.
