#!/usr/bin/env python3
"""Choose an available port that can bind IPv4 and IPv6 loopback."""

import socket
import sys


def available(port):
    sockets = []
    try:
        ipv4 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sockets.append(ipv4)
        ipv4.bind(("127.0.0.1", port))
        selected = ipv4.getsockname()[1]
        ipv6 = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        sockets.append(ipv6)
        ipv6.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        ipv6.bind(("::1", selected))
        return selected
    except OSError:
        return None
    finally:
        for sock in sockets:
            sock.close()


if len(sys.argv) > 1:
    selected = available(int(sys.argv[1]))
    if selected is None:
        raise SystemExit(f"loopback test port {sys.argv[1]} is unavailable")
else:
    selected = available(4101)
    if selected is None:
        selected = available(0)
    if selected is None:
        raise SystemExit("no port is available on both IPv4 and IPv6 loopback")

print(selected)
