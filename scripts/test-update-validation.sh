#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/minttorrent-update-test.XXXXXX")"
trap 'rm -rf -- "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/good/MintTorrent-test"
printf 'payload\n' > "$WORK_DIR/good/MintTorrent-test/file.txt"
tar -C "$WORK_DIR/good" -czf "$WORK_DIR/valid.tar.gz" MintTorrent-test
sha256sum "$WORK_DIR/valid.tar.gz" > "$WORK_DIR/valid.tar.gz.sha256"
"$ROOT_DIR/update.sh" --verify-only --bundle "$WORK_DIR/valid.tar.gz" >/dev/null

cp "$WORK_DIR/valid.tar.gz" "$WORK_DIR/tampered.tar.gz"
cp "$WORK_DIR/valid.tar.gz.sha256" "$WORK_DIR/tampered.tar.gz.sha256"
printf X | dd of="$WORK_DIR/tampered.tar.gz" bs=1 seek=8 conv=notrunc status=none
if "$ROOT_DIR/update.sh" --verify-only --bundle "$WORK_DIR/tampered.tar.gz" >"$WORK_DIR/tampered.log" 2>&1; then
  echo 'FAIL: checksum mismatch was accepted' >&2
  exit 1
fi
grep -q 'SHA-256 does not match' "$WORK_DIR/tampered.log"

python3 - "$WORK_DIR/traversal.tar.gz" <<'PY'
import io
import sys
import tarfile

with tarfile.open(sys.argv[1], "w:gz") as archive:
    item = tarfile.TarInfo("MintTorrent-test/../escape")
    data = b"unsafe"
    item.size = len(data)
    archive.addfile(item, io.BytesIO(data))
PY
sha256sum "$WORK_DIR/traversal.tar.gz" > "$WORK_DIR/traversal.tar.gz.sha256"
if "$ROOT_DIR/update.sh" --verify-only --bundle "$WORK_DIR/traversal.tar.gz" >"$WORK_DIR/traversal.log" 2>&1; then
  echo 'FAIL: path traversal archive was accepted' >&2
  exit 1
fi
grep -q 'Unsafe archive path' "$WORK_DIR/traversal.log"

python3 - "$WORK_DIR/link.tar.gz" <<'PY'
import sys
import tarfile

with tarfile.open(sys.argv[1], "w:gz") as archive:
    item = tarfile.TarInfo("MintTorrent-test/link")
    item.type = tarfile.SYMTYPE
    item.linkname = "../../outside"
    archive.addfile(item)
PY
sha256sum "$WORK_DIR/link.tar.gz" > "$WORK_DIR/link.tar.gz.sha256"
if "$ROOT_DIR/update.sh" --verify-only --bundle "$WORK_DIR/link.tar.gz" >"$WORK_DIR/link.log" 2>&1; then
  echo 'FAIL: unsafe symbolic link was accepted' >&2
  exit 1
fi
grep -q 'Unsafe symbolic-link target' "$WORK_DIR/link.log"

echo 'PASS: valid bundle accepted; bad checksum, traversal path, and unsafe symlink rejected.'
