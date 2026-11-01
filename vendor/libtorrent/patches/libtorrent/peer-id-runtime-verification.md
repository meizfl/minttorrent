# MintTorrent peer ID runtime verification

## Rationale

The MintTorrent engine is built against libtorrent ABI 2. The upstream
`session_handle::id()` accessor is only present in ABI 1, so the application
could configure a qBittorrent peer fingerprint without checking the ID that
the live session actually generates. Add `session_handle::get_peer_id()` for
ABI 2 and keep the deprecated ABI 1 accessor forwarding to it. The engine
configures `qBittorrent 5.3.0` (`-qB5300-`) and checks the actual generated
session ID immediately after session creation; startup fails if the prefix
does not match.

## Source changes

- `include/libtorrent/session_handle.hpp`: declare the ABI 2 accessor.
- `include/libtorrent/aux_/session_impl.hpp` and `src/session_impl.cpp`:
  expose the session's configured generated ID to the handle.
- `src/session_handle.cpp`: implement the public accessor and forward the old
  ABI 1 method to it.
- `src/minttorrent_engine.cpp`: configure the qBittorrent fingerprint and
  validate it against the constructed session.

## Reproducible build

From the repository root, using the documented Linux build dependencies:

```sh
cmake -S . -B build
cmake --build build --target minttorrent --parallel 4
```

`minttorrent_engine.cpp` runs the prefix assertion at runtime whenever the
active torrent session is created. The full repository check is
`cmake --build build --target minttorrent-check --parallel 4`; its loopback
smoke additionally requires the host to allow IPv4 and IPv6 loopback sockets.
