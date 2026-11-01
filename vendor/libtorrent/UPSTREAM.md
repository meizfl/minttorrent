# Vendored libtorrent

This directory contains the unmodified upstream libtorrent 2.1 source tree
from `arvidn/libtorrent`, branch `RC_2_1`, commit
`ed18015f5b894db382c385a516a85582f107b220` (2026-10-30).

Upstream license: BSD-3-Clause, see `LICENSE`. MintTorrent's own code and
qBittorrent WebUI distribution use GPL-3.0-or-later; this does not change the
license of the vendored upstream dependency.

MintTorrent-specific changes belong in this source tree and must be recorded
in `patches/libtorrent/` with a short rationale and a reproducible build
configuration. Do not edit generated files or silently update the upstream
revision.

For the non-WebRTC build, the required `deps/try_signal` submodule is included
at `105cce59972f925a33aa6b1c3109e4cd3caf583d`. WebRTC is disabled for this
product build, so `deps/libdatachannel` is intentionally omitted. Other
optional submodules are not needed by the selected configuration.
