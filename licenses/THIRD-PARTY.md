# Third-party runtime licenses

The bundle may carry these libraries when required by the build host:

| Component | License |
|---|---|
| OpenSSL | Apache-2.0; text in `runtime/OpenSSL-LICENSE.txt` |
| zlib | zlib License; text in `runtime/zlib-LICENSE.txt` |
| Brotli | MIT; text in `runtime/Brotli-LICENSE.txt` |
| Zstandard | BSD-3-Clause; text in `runtime/zstd-LICENSE.txt` |
| GCC runtime (`libgcc_s`, `libstdc++`) | GPL-3.0-or-later with GCC Runtime Library Exception; exception texts in `runtime/` and GPL text in the project `LICENSE` |
| libtorrent | BSD-3-Clause; upstream text shipped as `libtorrent-COPYING` |
| AmneziaWG-Go | MIT; upstream text shipped as `amneziawg-go-LICENSE` |
| Go standard library/runtime linked into the standalone API CLI | BSD-3-Clause; Go distribution text shipped as `Go-LICENSE` |
| `golang.org/x/term` used for portable hidden terminal input | BSD-3-Clause; shipped as `x-term-LICENSE.txt` |
| `golang.org/x/sys` used by `golang.org/x/term` platform adapters | BSD-3-Clause; shipped as `x-sys-LICENSE.txt` |

The original qBittorrent WebUI assets are part of the vendored qBittorrent
5.3.0 source tree (`vendor/qbittorrent/src/webui/www`) and retain the upstream
GPL-3.0-or-later license. The standalone bundle includes a matching offline
copy at `webui/qbittorrent/`.
