# Native components

## AmneziaWG-Go

`amneziawg-go` is copied from `github.com/amnezia-vpn/amneziawg-go/v3`, tag
`v3.1.20260828`, commit `b5928efb6ca19f0153958460c3d141f04abc5c2e`.
It is distributed under MIT; its upstream `LICENSE` remains in the source
directory. The bridge in `components/awgnet` embeds this dependency and uses
its official AmneziaWG device plus `tun/netstack` implementation.

The package emits a C shared library so the patched C++ qBittorrent/libtorrent
runtime can own an in-process AWG/gVisor stack. The Go ABI passes integer
handles and C buffers only; Go pointers are not retained by C++.
