#!/usr/bin/env python3
"""Scan source directories and tar/zip contents without displaying secret values."""
from pathlib import Path, PurePosixPath
import hashlib
import io
import json
import re
import sys
import tarfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
ALLOW_FILE = ROOT / 'config/public-test-fixtures.json'
ALLOW = json.loads(ALLOW_FILE.read_text()) if ALLOW_FILE.exists() else {}
PATTERNS = {
    'private PEM key': re.compile(rb'-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----\s+[A-Za-z0-9+/=\r\n]{40,}-----END (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----'),
    'WireGuard private/preshared key': re.compile(rb'(?im)\b(?:PrivateKey|PresharedKey|private_key|preshared_key)\s*[:=]\s*[\x22\x27]?([A-Za-z0-9+/]{43}=)'),
    'GitHub token': re.compile(rb'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b'),
    'AWS access key': re.compile(rb'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b'),
    'Slack token': re.compile(rb'\bxox[baprs]-[A-Za-z0-9-]{20,}\b'),
}
SKIP = {'.git', '.svn', '__pycache__', 'build', 'target', 'go', 'data', 'logs'}
failures = []
scanned = 0
fixtures = set()

def check(name, data, allow_fixture=False):
    global scanned
    scanned += 1
    hits = [label for label, pattern in PATTERNS.items() if pattern.search(data)]
    if not hits:
        return
    normalized = name.replace('\\', '/')
    expected = ALLOW.get(normalized) if allow_fixture else None
    if expected and hashlib.sha256(data).hexdigest() == expected:
        fixtures.add(normalized)
        return
    failures.extend(f'{name}: {label}' for label in hits)

def archive_name_ok(name):
    p = PurePosixPath(name)
    return not p.is_absolute() and '..' not in p.parts and '\\' not in name

def scan_file(path, label, allow_fixture=False):
    if path.name.endswith(('.tar.gz', '.tgz', '.tar', '.tar.xz')):
        with tarfile.open(path, 'r:*') as archive:
            for member in archive:
                if not archive_name_ok(member.name):
                    failures.append(f'{label}: unsafe archive path')
                if member.isfile():
                    stream = archive.extractfile(member)
                    check(f'{label}!{member.name}', stream.read())
                elif member.issym() and (PurePosixPath(member.linkname).is_absolute() or '..' in PurePosixPath(member.linkname).parts):
                    failures.append(f'{label}!{member.name}: unsafe symlink')
    elif path.suffix.lower() == '.zip':
        with zipfile.ZipFile(path) as archive:
            for member in archive.infolist():
                if not archive_name_ok(member.filename):
                    failures.append(f'{label}: unsafe archive path')
                if not member.is_dir():
                    check(f'{label}!{member.filename}', archive.read(member))
    else:
        check(label, path.read_bytes(), allow_fixture)

def scan(target):
    if target.is_file():
        scan_file(target, target.name)
        return
    for path in sorted(target.rglob('*')):
        relative = path.relative_to(target)
        if any(part in {'.git', '.svn', '__pycache__'} for part in relative.parts[:-1]) or (len(relative.parts) > 1 and relative.parts[0] in SKIP):
            continue
        if path.is_symlink():
            try:
                path.resolve().relative_to(target.resolve())
            except ValueError:
                failures.append(f'{relative}: symlink escapes tree')
            continue
        if not path.is_file():
            continue
        # Fixture exceptions apply only to the canonical source tree, never assets.
        fixture = target.resolve() == ROOT.resolve()
        if path.name.startswith('.env') and not path.name.endswith('.example'):
            failures.append(f'{relative}: local environment file')
        scan_file(path, relative.as_posix(), fixture)

if __name__ == '__main__':
    for argument in sys.argv[1:] or [str(ROOT)]:
        scan(Path(argument).resolve())
    if failures:
        for finding in failures:
            print('FAIL: ' + finding, file=sys.stderr)
        raise SystemExit(1)
    print(f'PASS: {scanned} files/archive members scanned; no unapproved credentials found; {len(fixtures)} public fixture exceptions verified.')
