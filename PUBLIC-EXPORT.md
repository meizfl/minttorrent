# Public export verification — 2026-11-01

This source tree contains the current patched runtime, desktop branding,
build/packaging tools, container build kit, tests, licenses and public CI.
Local build caches, generated release archives, operator configuration, state,
logs and original Git metadata were not copied.

Public source scanning passed, including inspection of source archive members.
Exact encoded and decoded values from the local operator's private, preshared
and public VPN keys were checked independently and had no matches. Only pinned
public upstream test-key fixtures are exempted in the source tree; exceptions
require an exact SHA-256 match. The six scanner regression tests passed.

Both sanitized server archives passed layout/checksum validation and loopback
smoke tests: authenticated WebUI/API and CLI, VPN-disabled state and invalid
settings rejection, torrent/tracker CRUD, metadata persistence and IPv4/IPv6
loopback. These checks did not activate a VPN or connect to a torrent swarm.
All five release assets have unchanged compiled ELF/PE runtime payloads.

The source CMake project configures, shell/Python syntax checks pass, and CLI
Go unit tests pass. Public CI YAML was parsed locally. The Windows dependency
bootstrap and revised CI are supplied for clean builds; a hosted CI run has
not been performed as part of this local export.

Release archives belong in the sibling `github-releases` directory, not this
source repository. That directory contains credential-free assets, checksums,
release notes and a publication audit record.
