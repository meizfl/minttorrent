#!/usr/bin/env python3
"""Fail unless captured outbound public packets target only the AWG endpoint."""

import ipaddress
import re
import sys

if len(sys.argv) != 4:
    raise SystemExit("usage: verify-packet-capture.py TCPDUMP_LOG AWG_ENDPOINT LOCAL_ADDRESS")

capture_path, endpoint, local_address = sys.argv[1:]
endpoint = ipaddress.ip_address(endpoint)
local_address = ipaddress.ip_address(local_address)
destinations = set()
captured = 0

for line in open(capture_path, encoding="utf-8", errors="replace"):
    match = re.search(r"\bIP6?\s+(.+?)\s+>\s+(.+?):\s", line)
    if not match:
        continue
    value = match.group(2).strip()
    if value.startswith("[") and "]" in value:
        host = value[1:value.index("]")]
    else:
        try:
            ipaddress.ip_address(value.split("%", 1)[0])
            host = value
        except ValueError:
            host = value.rsplit(".", 1)[0]
    host = host.split("%", 1)[0]
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        continue
    captured += 1
    # The relay test may address the machine's own local interface IP. It is
    # looped back by the kernel and does not represent a remote destination.
    if address.is_global and address != local_address:
        destinations.add(address)

if captured == 0:
    raise SystemExit("No outbound IPv4/IPv6 packets were captured; cannot accept this run")
if endpoint not in destinations:
    raise SystemExit(
        f"Configured AWG endpoint {endpoint} was absent from capture; "
        f"public destinations={sorted(map(str, destinations))}"
    )
unexpected = destinations - {endpoint}
if unexpected:
    raise SystemExit(
        f"Unexpected public packet destinations captured: {sorted(map(str, unexpected))}; "
        f"allowed AWG endpoint={endpoint}"
    )
print(f"PASS: captured {captured} outbound IP packets; the only public destination was AWG endpoint {endpoint}.")
