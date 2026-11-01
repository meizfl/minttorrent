#!/usr/bin/env python3
"""Fail if any bundled ELF requires a GLIBC symbol newer than the target."""

from pathlib import Path
import re
import subprocess
import sys


if len(sys.argv) != 3:
    raise SystemExit("usage: check-glibc-requirements.py BUNDLE_DIR MAX_VERSION")

root = Path(sys.argv[1])
maximum = tuple(map(int, sys.argv[2].split("."))) + (0,)
pattern = re.compile(r"GLIBC_(\d+)\.(\d+)(?:\.(\d+))?")
failures = []
scanned = 0

for path in root.rglob("*"):
    if not path.is_file():
        continue
    try:
        with path.open("rb") as stream:
            if stream.read(4) != b"\x7fELF":
                continue
    except OSError:
        continue
    scanned += 1
    result = subprocess.run(
        ["readelf", "--version-info", str(path)],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode:
        raise SystemExit(f"readelf failed for {path}: {result.stderr.strip()}")
    versions = [
        tuple(int(part or 0) for part in match.groups())
        for match in pattern.finditer(result.stdout)
    ]
    newer = max((version for version in versions if version > maximum), default=None)
    if newer:
        failures.append((path.relative_to(root), newer))

if failures:
    for path, version in failures:
        print(f"FAIL: {path} requires GLIBC_{'.'.join(map(str, version))}", file=sys.stderr)
    raise SystemExit(1)

print(f"PASS: scanned {scanned} ELF files; none requires a GLIBC symbol newer than {sys.argv[2]}.")
