#!/usr/bin/env python3
"""Per-run UDP relay for AWG outage testing, bound to the routed local address."""

import ipaddress
import pathlib
import re
import signal
import socket
import sys
import time

running = True


def stop(_signum, _frame):
    global running
    running = False


def main() -> int:
    if len(sys.argv) != 4:
        raise SystemExit("usage: udp-underlay-relay.py AWG_PROFILE READY_FILE DROP_FILE")
    profile = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
    ready_file = pathlib.Path(sys.argv[2])
    drop_file = pathlib.Path(sys.argv[3])
    match = re.search(r"(?im)^\s*Endpoint\s*=\s*(\[[^]]+\]|[^\s:]+):([0-9]{1,5})\s*$", profile)
    if not match:
        raise SystemExit("AWG profile must have one numeric Endpoint = address:port")
    try:
        remote_ip = ipaddress.ip_address(match.group(1).strip("[]"))
    except ValueError as exc:
        raise SystemExit("UDP relay requires a numeric AWG endpoint") from exc
    remote_port = int(match.group(2))
    if not 1 <= remote_port <= 65535:
        raise SystemExit("AWG endpoint port is outside the valid range")
    family = socket.AF_INET6 if remote_ip.version == 6 else socket.AF_INET
    remote = (str(remote_ip), remote_port, 0, 0) if family == socket.AF_INET6 else (str(remote_ip), remote_port)

    route_probe = socket.socket(family, socket.SOCK_DGRAM)
    try:
        route_probe.connect(remote)
        local_ip = route_probe.getsockname()[0]
    finally:
        route_probe.close()
    if ipaddress.ip_address(local_ip).is_unspecified or ipaddress.ip_address(local_ip).is_loopback:
        raise SystemExit("route selection did not produce a non-loopback local address")

    relay = socket.socket(family, socket.SOCK_DGRAM)
    relay.bind((local_ip, 0))
    relay.settimeout(0.5)
    local_port = relay.getsockname()[1]
    ready_file.write_text(f"{local_ip}:{local_port}\n", encoding="ascii")
    client = None
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        while running:
            try:
                payload, source = relay.recvfrom(65535)
            except socket.timeout:
                continue
            if drop_file.exists():
                continue
            if (source[0] == str(remote_ip)) and (source[1] == remote_port):
                if client is not None:
                    relay.sendto(payload, client)
            else:
                client = source
                relay.sendto(payload, remote)
    finally:
        relay.close()
        try:
            ready_file.unlink()
        except FileNotFoundError:
            pass
        time.sleep(0.05)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
