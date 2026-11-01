#!/usr/bin/env python3
"""Exercise the tcpdump destination parser with IPv4/IPv6 fixtures."""

import subprocess
import sys
import tempfile
from pathlib import Path

checker = Path(__file__).with_name("verify-packet-capture.py")


def check(lines: list[str], endpoint: str, local_address: str, succeeds: bool) -> None:
    with tempfile.TemporaryDirectory(prefix="minttorrent-capture-parser-") as directory:
        capture = Path(directory) / "tcpdump.log"
        capture.write_text("\n".join(lines) + "\n", encoding="utf-8")
        result = subprocess.run(
            [sys.executable, str(checker), str(capture), endpoint, local_address],
            text=True,
            capture_output=True,
            check=False,
        )
        if (result.returncode == 0) != succeeds:
            raise AssertionError(
                f"checker return code {result.returncode}, expected success={succeeds}; "
                f"stdout={result.stdout!r}; stderr={result.stderr!r}"
            )


check(
    [
        "1700000000.1 eth0 Out IP 192.168.1.2.40233 > 162.159.193.1.2408: UDP, length 100",
        # A local relay address can itself be publicly routed; it is not a
        # remote destination and must be excluded from the public allow-list.
        "1700000000.2 eth0 Out IP 192.168.1.2.40233 > 8.8.8.8.51000: UDP, length 100",
    ],
    "162.159.193.1",
    "8.8.8.8",
    True,
)
check(
    [
        "1700000000.1 eth0 Out IP6 2001:db8::20.45321 > 2606:4700:4700::1111.443: UDP, length 80",
    ],
    "2606:4700:4700::1111",
    "2001:db8::20",
    True,
)
check(
    [
        "1700000000.1 eth0 Out IP 192.168.1.2.40233 > 162.159.193.1.2408: UDP, length 100",
        "1700000000.2 eth0 Out IP 192.168.1.2.40233 > 1.1.1.1.443: UDP, length 100",
    ],
    "162.159.193.1",
    "192.168.1.2",
    False,
)
check([], "162.159.193.1", "192.168.1.2", False)

print("PASS: packet-capture parser handles IPv4/IPv6, local relay traffic, and rejects unexpected public destinations.")
